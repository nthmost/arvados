package main

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"

	"git.curoverse.com/arvados.git/sdk/go/arvados"
	"gopkg.in/src-d/go-billy.v4/osfs"
	git "gopkg.in/src-d/go-git.v4"
	git_config "gopkg.in/src-d/go-git.v4/config"
	git_plumbing "gopkg.in/src-d/go-git.v4/plumbing"
	git_http "gopkg.in/src-d/go-git.v4/plumbing/transport/http"
	"gopkg.in/src-d/go-git.v4/storage/memory"
)

type gitMount arvados.Mount

var (
	sha1re     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	repoUUIDre = regexp.MustCompile(`^[0-9a-z]{5}-s0uqq-[0-9a-z]{15}$`)
)

func (gm gitMount) validate() error {
	if gm.Path != "" && gm.Path != "/" {
		return fmt.Errorf("cannot mount git_tree with path %q -- only \"/\" is supported", gm.Path)
	}
	if !sha1re.MatchString(gm.Commit) {
		return fmt.Errorf("cannot mount git_tree with commit %q -- must be a 40-char SHA1", gm.Commit)
	}
	if gm.RepositoryName != "" || gm.GitURL != "" {
		return fmt.Errorf("cannot mount git_tree -- repository_name and git_url must be empty")
	}
	if !repoUUIDre.MatchString(gm.UUID) {
		return fmt.Errorf("cannot mount git_tree with uuid %q -- must be a repository UUID", gm.UUID)
	}
	if gm.Writable {
		return fmt.Errorf("writable git_tree mount is not supported")
	}
	return nil
}

// ExtractTree extracts the specified tree into dir, which is an
// existing empty local directory.
func (gm gitMount) extractTree(ac IArvadosClient, dir string, token string) error {
	err := gm.validate()
	if err != nil {
		return err
	}
	baseURL, err := ac.Discovery("gitUrl")
	if err != nil {
		return fmt.Errorf("discover gitUrl from API: %s", err)
	} else if _, ok := baseURL.(string); !ok {
		return fmt.Errorf("discover gitUrl from API: expected string, found %T", baseURL)
	}

	u, err := url.Parse(baseURL.(string))
	if err != nil {
		return fmt.Errorf("parse gitUrl %q: %s", baseURL, err)
	}
	u, err = u.Parse("/" + gm.UUID + ".git")
	if err != nil {
		return fmt.Errorf("build git url from %q, %q: %s", baseURL, gm.UUID, err)
	}
	store := memory.NewStorage()
	repo, err := git.Init(store, osfs.New(dir))
	if err != nil {
		return fmt.Errorf("init repo: %s", err)
	}
	_, err = repo.CreateRemote(&git_config.RemoteConfig{
		Name: "origin",
		URLs: []string{u.String()},
	})
	if err != nil {
		return fmt.Errorf("create remote %q: %s", u.String(), err)
	}
	err = repo.Fetch(&git.FetchOptions{
		RemoteName: "origin",
		Auth: &git_http.BasicAuth{
			Username: "none",
			Password: token,
		},
	})
	if err != nil {
		return fmt.Errorf("git fetch %q: %s", u.String(), err)
	}
	wt, err := repo.Worktree()
	if err != nil {
		return fmt.Errorf("worktree failed: %s", err)
	}
	err = wt.Checkout(&git.CheckoutOptions{
		Hash: git_plumbing.NewHash(gm.Commit),
	})
	if err != nil {
		return fmt.Errorf("checkout failed: %s", err)
	}
	err = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		// copy user rx bits to group and other, in case
		// prevailing umask is more restrictive than 022
		mode := info.Mode()
		mode = mode | ((mode >> 3) & 050) | ((mode >> 6) & 5)
		return os.Chmod(path, mode)
	})
	if err != nil {
		return fmt.Errorf("chmod -R %q: %s", dir, err)
	}
	return nil
}
