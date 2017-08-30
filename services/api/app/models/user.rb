# Copyright (C) The Arvados Authors. All rights reserved.
#
# SPDX-License-Identifier: AGPL-3.0

require 'can_be_an_owner'

class User < ArvadosModel
  include HasUuid
  include KindAndEtag
  include CommonApiTemplate
  include CanBeAnOwner

  # To avoid upgrade bugs, when changing the permission cache value
  # format, change PERM_CACHE_PREFIX too:
  PERM_CACHE_PREFIX = "perm_v20170725_"
  PERM_CACHE_TTL = 172800

  serialize :prefs, Hash
  has_many :api_client_authorizations
  validates(:username,
            format: {
              with: /\A[A-Za-z][A-Za-z0-9]*\z/,
              message: "must begin with a letter and contain only alphanumerics",
            },
            uniqueness: true,
            allow_nil: true)
  before_update :prevent_privilege_escalation
  before_update :prevent_inactive_admin
  before_update :verify_repositories_empty, :if => Proc.new { |user|
    user.username.nil? and user.username_changed?
  }
  before_update :setup_on_activate
  before_create :check_auto_admin
  before_create :set_initial_username, :if => Proc.new { |user|
    user.username.nil? and user.email
  }
  after_create :add_system_group_permission_link
  after_create :auto_setup_new_user, :if => Proc.new { |user|
    Rails.configuration.auto_setup_new_users and
    (user.uuid != system_user_uuid) and
    (user.uuid != anonymous_user_uuid)
  }
  after_create :send_admin_notifications
  after_update :send_profile_created_notification
  after_update :sync_repository_names, :if => Proc.new { |user|
    (user.uuid != system_user_uuid) and
    user.username_changed? and
    (not user.username_was.nil?)
  }

  has_many :authorized_keys, :foreign_key => :authorized_user_uuid, :primary_key => :uuid
  has_many :repositories, foreign_key: :owner_uuid, primary_key: :uuid

  api_accessible :user, extend: :common do |t|
    t.add :email
    t.add :username
    t.add :full_name
    t.add :first_name
    t.add :last_name
    t.add :identity_url
    t.add :is_active
    t.add :is_admin
    t.add :is_invited
    t.add :prefs
    t.add :writable_by
  end

  ALL_PERMISSIONS = {read: true, write: true, manage: true}

  # Map numeric permission levels (see lib/create_permission_view.sql)
  # back to read/write/manage flags.
  PERMS_FOR_VAL =
    [{},
     {read: true},
     {read: true, write: true},
     {read: true, write: true, manage: true}]

  def full_name
    "#{first_name} #{last_name}".strip
  end

  def is_invited
    !!(self.is_active ||
       Rails.configuration.new_users_are_active ||
       self.groups_i_can(:read).select { |x| x.match(/-f+$/) }.first)
  end

  def groups_i_can(verb)
    my_groups = self.group_permissions.select { |uuid, mask| mask[verb] }.keys
    if verb == :read
      my_groups << anonymous_group_uuid
    end
    my_groups
  end

  def can?(actions)
    return true if is_admin
    actions.each do |action, target|
      unless target.nil?
        if target.respond_to? :uuid
          target_uuid = target.uuid
        else
          target_uuid = target
          target = ArvadosModel.find_by_uuid(target_uuid)
        end
      end
      next if target_uuid == self.uuid
      next if (group_permissions[target_uuid] and
               group_permissions[target_uuid][action])
      if target.respond_to? :owner_uuid
        next if target.owner_uuid == self.uuid
        next if (group_permissions[target.owner_uuid] and
                 group_permissions[target.owner_uuid][action])
      end
      sufficient_perms = case action
                         when :manage
                           ['can_manage']
                         when :write
                           ['can_manage', 'can_write']
                         when :read
                           ['can_manage', 'can_write', 'can_read']
                         else
                           # (Skip this kind of permission opportunity
                           # if action is an unknown permission type)
                         end
      if sufficient_perms
        # Check permission links with head_uuid pointing directly at
        # the target object. If target is a Group, this is redundant
        # and will fail except [a] if permission caching is broken or
        # [b] during a race condition, where a permission link has
        # *just* been added.
        if Link.where(link_class: 'permission',
                      name: sufficient_perms,
                      tail_uuid: groups_i_can(action) + [self.uuid],
                      head_uuid: target_uuid).any?
          next
        end
      end
      return false
    end
    true
  end

  def self.invalidate_permissions_cache(timestamp=nil)
    if Rails.configuration.async_permissions_update
      timestamp = DbCurrentTime::db_current_time.to_i if timestamp.nil?
      connection.execute "NOTIFY invalidate_permissions_cache, '#{timestamp}'"
    else
      Rails.cache.delete_matched(/^#{PERM_CACHE_PREFIX}/)
    end
  end

  # Return a hash of {user_uuid: group_perms}
  def self.all_group_permissions
    all_perms = {}
    User.install_view('permission')
    ActiveRecord::Base.connection.
      exec_query('SELECT user_uuid, target_owner_uuid, perm_level, trashed
                  FROM permission_view
                  WHERE target_owner_uuid IS NOT NULL',
                  # "name" arg is a query label that appears in logs:
                  "all_group_permissions",
                  ).rows.each do |user_uuid, group_uuid, max_p_val, trashed|
      all_perms[user_uuid] ||= {user_uuid => {:read => true, :write => true, :manage => true}}
      all_perms[user_uuid][group_uuid] = PERMS_FOR_VAL[max_p_val.to_i]
    end
    all_perms
  end

  # Return a hash of {group_uuid: perm_hash} where perm_hash[:read]
  # and perm_hash[:write] are true if this user can read and write
  # objects owned by group_uuid.
  def calculate_group_permissions
    group_perms = {self.uuid => {:read => true, :write => true, :manage => true}}
    User.install_view('permission')
    ActiveRecord::Base.connection.
      exec_query('SELECT target_owner_uuid, perm_level, trashed
                  FROM permission_view
                  WHERE user_uuid = $1
                  AND target_owner_uuid IS NOT NULL',
                  # "name" arg is a query label that appears in logs:
                  "group_permissions for #{uuid}",
                  # "binds" arg is an array of [col_id, value] for '$1' vars:
                  [[nil, uuid]],
                ).rows.each do |group_uuid, max_p_val, trashed|
      group_perms[group_uuid] = PERMS_FOR_VAL[max_p_val.to_i]
    end
    Rails.cache.write "#{PERM_CACHE_PREFIX}#{self.uuid}", group_perms, expires_in: PERM_CACHE_TTL
    group_perms
  end

  # Return a hash of {group_uuid: perm_hash} where perm_hash[:read]
  # and perm_hash[:write] are true if this user can read and write
  # objects owned by group_uuid.
  def group_permissions
    r = Rails.cache.read "#{PERM_CACHE_PREFIX}#{self.uuid}"
    if r.nil?
      if Rails.configuration.async_permissions_update
        while r.nil?
          sleep(0.1)
          r = Rails.cache.read "#{PERM_CACHE_PREFIX}#{self.uuid}"
        end
      else
        r = calculate_group_permissions
      end
    end
    r
  end

  # create links
  def setup(openid_prefix:, repo_name: nil, vm_uuid: nil)
    oid_login_perm = create_oid_login_perm openid_prefix
    repo_perm = create_user_repo_link repo_name
    vm_login_perm = create_vm_login_permission_link(vm_uuid, username) if vm_uuid
    group_perm = create_user_group_link

    return [oid_login_perm, repo_perm, vm_login_perm, group_perm, self].compact
  end

  # delete user signatures, login, repo, and vm perms, and mark as inactive
  def unsetup
    # delete oid_login_perms for this user
    Link.destroy_all(tail_uuid: self.email,
                     link_class: 'permission',
                     name: 'can_login')

    # delete repo_perms for this user
    Link.destroy_all(tail_uuid: self.uuid,
                     link_class: 'permission',
                     name: 'can_manage')

    # delete vm_login_perms for this user
    Link.destroy_all(tail_uuid: self.uuid,
                     link_class: 'permission',
                     name: 'can_login')

    # delete "All users" group read permissions for this user
    group = Group.where(name: 'All users').select do |g|
      g[:uuid].match(/-f+$/)
    end.first
    Link.destroy_all(tail_uuid: self.uuid,
                     head_uuid: group[:uuid],
                     link_class: 'permission',
                     name: 'can_read')

    # delete any signatures by this user
    Link.destroy_all(link_class: 'signature',
                     tail_uuid: self.uuid)

    # delete user preferences (including profile)
    self.prefs = {}

    # mark the user as inactive
    self.is_active = false
    self.save!
  end

  def set_initial_username(requested: false)
    if !requested.is_a?(String) || requested.empty?
      email_parts = email.partition("@")
      local_parts = email_parts.first.partition("+")
      if email_parts.any?(&:empty?)
        return
      elsif not local_parts.first.empty?
        requested = local_parts.first
      else
        requested = email_parts.first
      end
    end
    requested.sub!(/^[^A-Za-z]+/, "")
    requested.gsub!(/[^A-Za-z0-9]/, "")
    unless requested.empty?
      self.username = find_usable_username_from(requested)
    end
  end

  protected

  def ensure_ownership_path_leads_to_user
    true
  end

  def permission_to_update
    if username_changed?
      current_user.andand.is_admin
    else
      # users must be able to update themselves (even if they are
      # inactive) in order to create sessions
      self == current_user or super
    end
  end

  def permission_to_create
    current_user.andand.is_admin or
      (self == current_user and
       self.is_active == Rails.configuration.new_users_are_active)
  end

  def check_auto_admin
    return if self.uuid.end_with?('anonymouspublic')
    if (User.where("email = ?",self.email).where(:is_admin => true).count == 0 and
        Rails.configuration.auto_admin_user and self.email == Rails.configuration.auto_admin_user) or
       (User.where("uuid not like '%-000000000000000'").where(:is_admin => true).count == 0 and
        Rails.configuration.auto_admin_first_user)
      self.is_admin = true
      self.is_active = true
    end
  end

  def find_usable_username_from(basename)
    # If "basename" is a usable username, return that.
    # Otherwise, find a unique username "basenameN", where N is the
    # smallest integer greater than 1, and return that.
    # Return nil if a unique username can't be found after reasonable
    # searching.
    quoted_name = self.class.connection.quote_string(basename)
    next_username = basename
    next_suffix = 1
    while Rails.configuration.auto_setup_name_blacklist.include?(next_username)
      next_suffix += 1
      next_username = "%s%i" % [basename, next_suffix]
    end
    0.upto(6).each do |suffix_len|
      pattern = "%s%s" % [quoted_name, "_" * suffix_len]
      self.class.
          where("username like '#{pattern}'").
          select(:username).
          order('username asc').
          each do |other_user|
        if other_user.username > next_username
          break
        elsif other_user.username == next_username
          next_suffix += 1
          next_username = "%s%i" % [basename, next_suffix]
        end
      end
      return next_username if (next_username.size <= pattern.size)
    end
    nil
  end

  def prevent_privilege_escalation
    if current_user.andand.is_admin
      return true
    end
    if self.is_active_changed?
      if self.is_active != self.is_active_was
        logger.warn "User #{current_user.uuid} tried to change is_active from #{self.is_admin_was} to #{self.is_admin} for #{self.uuid}"
        self.is_active = self.is_active_was
      end
    end
    if self.is_admin_changed?
      if self.is_admin != self.is_admin_was
        logger.warn "User #{current_user.uuid} tried to change is_admin from #{self.is_admin_was} to #{self.is_admin} for #{self.uuid}"
        self.is_admin = self.is_admin_was
      end
    end
    true
  end

  def prevent_inactive_admin
    if self.is_admin and not self.is_active
      # There is no known use case for the strange set of permissions
      # that would result from this change. It's safest to assume it's
      # a mistake and disallow it outright.
      raise "Admin users cannot be inactive"
    end
    true
  end

  def search_permissions(start, graph, merged={}, upstream_mask=nil, upstream_path={})
    nextpaths = graph[start]
    return merged if !nextpaths
    return merged if upstream_path.has_key? start
    upstream_path[start] = true
    upstream_mask ||= ALL_PERMISSIONS
    nextpaths.each do |head, mask|
      merged[head] ||= {}
      mask.each do |k,v|
        merged[head][k] ||= v if upstream_mask[k]
      end
      search_permissions(head, graph, merged, upstream_mask.select { |k,v| v && merged[head][k] }, upstream_path)
    end
    upstream_path.delete start
    merged
  end

  def create_oid_login_perm(openid_prefix)
    # Check oid_login_perm
    oid_login_perms = Link.where(tail_uuid: self.email,
                                 head_uuid: self.uuid,
                                 link_class: 'permission',
                                 name: 'can_login')

    if !oid_login_perms.any?
      # create openid login permission
      oid_login_perm = Link.create(link_class: 'permission',
                                   name: 'can_login',
                                   tail_uuid: self.email,
                                   head_uuid: self.uuid,
                                   properties: {
                                     "identity_url_prefix" => openid_prefix,
                                   })
      logger.info { "openid login permission: " + oid_login_perm[:uuid] }
    else
      oid_login_perm = oid_login_perms.first
    end

    return oid_login_perm
  end

  def create_user_repo_link(repo_name)
    # repo_name is optional
    if not repo_name
      logger.warn ("Repository name not given for #{self.uuid}.")
      return
    end

    repo = Repository.where(owner_uuid: uuid, name: repo_name).first_or_create!
    logger.info { "repo uuid: " + repo[:uuid] }
    repo_perm = Link.where(tail_uuid: uuid, head_uuid: repo.uuid,
                           link_class: "permission",
                           name: "can_manage").first_or_create!
    logger.info { "repo permission: " + repo_perm[:uuid] }
    return repo_perm
  end

  # create login permission for the given vm_uuid, if it does not already exist
  def create_vm_login_permission_link(vm_uuid, repo_name)
    # vm uuid is optional
    return if !vm_uuid

    vm = VirtualMachine.where(uuid: vm_uuid).first
    if !vm
      logger.warn "Could not find virtual machine for #{vm_uuid.inspect}"
      raise "No vm found for #{vm_uuid}"
    end

    logger.info { "vm uuid: " + vm[:uuid] }
    login_attrs = {
      tail_uuid: uuid, head_uuid: vm.uuid,
      link_class: "permission", name: "can_login",
    }

    login_perm = Link.
      where(login_attrs).
      select { |link| link.properties["username"] == repo_name }.
      first

    login_perm ||= Link.
      create(login_attrs.merge(properties: {"username" => repo_name}))

    logger.info { "login permission: " + login_perm[:uuid] }
    login_perm
  end

  # add the user to the 'All users' group
  def create_user_group_link
    return (Link.where(tail_uuid: self.uuid,
                       head_uuid: all_users_group[:uuid],
                       link_class: 'permission',
                       name: 'can_read').first or
            Link.create(tail_uuid: self.uuid,
                        head_uuid: all_users_group[:uuid],
                        link_class: 'permission',
                        name: 'can_read'))
  end

  # Give the special "System group" permission to manage this user and
  # all of this user's stuff.
  def add_system_group_permission_link
    return true if uuid == system_user_uuid
    act_as_system_user do
      Link.create(link_class: 'permission',
                  name: 'can_manage',
                  tail_uuid: system_group_uuid,
                  head_uuid: self.uuid)
    end
  end

  # Send admin notifications
  def send_admin_notifications
    AdminNotifier.new_user(self).deliver_now
    if not self.is_active then
      AdminNotifier.new_inactive_user(self).deliver_now
    end
  end

  # Automatically setup if is_active flag turns on
  def setup_on_activate
    return if [system_user_uuid, anonymous_user_uuid].include?(self.uuid)
    if is_active && (new_record? || is_active_changed?)
      setup(openid_prefix: Rails.configuration.default_openid_prefix)
    end
  end

  # Automatically setup new user during creation
  def auto_setup_new_user
    setup(openid_prefix: Rails.configuration.default_openid_prefix)
    if username
      create_vm_login_permission_link(Rails.configuration.auto_setup_new_users_with_vm_uuid,
                                      username)
      repo_name = "#{username}/#{username}"
      if Rails.configuration.auto_setup_new_users_with_repository and
          Repository.where(name: repo_name).first.nil?
        repo = Repository.create!(name: repo_name, owner_uuid: uuid)
        Link.create!(tail_uuid: uuid, head_uuid: repo.uuid,
                     link_class: "permission", name: "can_manage")
      end
    end
  end

  # Send notification if the user saved profile for the first time
  def send_profile_created_notification
    if self.prefs_changed?
      if self.prefs_was.andand.empty? || !self.prefs_was.andand['profile']
        profile_notification_address = Rails.configuration.user_profile_notification_address
        ProfileNotifier.profile_created(self, profile_notification_address).deliver_now if profile_notification_address
      end
    end
  end

  def verify_repositories_empty
    unless repositories.first.nil?
      errors.add(:username, "can't be unset when the user owns repositories")
      false
    end
  end

  def sync_repository_names
    old_name_re = /^#{Regexp.escape(username_was)}\//
    name_sub = "#{username}/"
    repositories.find_each do |repo|
      repo.name = repo.name.sub(old_name_re, name_sub)
      repo.save!
    end
  end
end
