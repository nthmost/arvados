FakeRESTService <- R6::R6Class(

    "FakeRESTService",

    public = list(

        getResourceCallCount    = NULL,
        createResourceCallCount = NULL,
        listResourcesCallCount  = NULL,
        deleteResourceCallCount = NULL,
        updateResourceCallCount = NULL,
        fetchAllItemsCallCount  = NULL,

        createCallCount               = NULL,
        deleteCallCount               = NULL,
        moveCallCount                 = NULL,
        getCollectionContentCallCount = NULL,
        getResourceSizeCallCount      = NULL,
        readCallCount                 = NULL,
        writeCallCount                = NULL,
        getConnectionCallCount        = NULL,
        writeBuffer                   = NULL,
        filtersAreConfiguredCorrectly = NULL,
        bodyIsConfiguredCorrectly     = NULL,
        expectedFilterContent         = NULL,

        collectionContent = NULL,
        returnContent     = NULL,

        initialize = function(collectionContent = NULL, returnContent = NULL, 
                              expectedFilterContent = NULL)
        {
            self$getResourceCallCount    <- 0
            self$createResourceCallCount <- 0
            self$listResourcesCallCount  <- 0
            self$deleteResourceCallCount <- 0
            self$updateResourceCallCount <- 0
            self$fetchAllItemsCallCount  <- 0

            self$createCallCount               <- 0
            self$deleteCallCount               <- 0
            self$moveCallCount                 <- 0
            self$getCollectionContentCallCount <- 0
            self$getResourceSizeCallCount      <- 0
            self$readCallCount                 <- 0
            self$writeCallCount                <- 0
            self$getConnectionCallCount        <- 0
            self$filtersAreConfiguredCorrectly <- FALSE
            self$bodyIsConfiguredCorrectly     <- FALSE

            self$collectionContent     <- collectionContent
            self$returnContent         <- returnContent
            self$expectedFilterContent <- expectedFilterContent
        },

        getWebDavHostName = function()
        {
        },

        getResource = function(resource, uuid)
        {
            self$getResourceCallCount <- self$getResourceCallCount + 1
            self$returnContent
        },

        listResources = function(resource, filters = NULL, limit = 100, offset = 0)
        {
            self$listResourcesCallCount <- self$listResourcesCallCount + 1

            if(!is.null(self$expectedFilterContent) && !is.null(filters))
               if(all.equal(filters, self$expectedFilterContent))
                    self$filtersAreConfiguredCorrectly <- TRUE

            self$returnContent
        },

        fetchAllItems = function(resourceURL, filters)
        {
            self$fetchAllItemsCallCount <- self$fetchAllItemsCallCount + 1

            if(!is.null(self$expectedFilterContent) && !is.null(filters))
               if(all.equal(filters, self$expectedFilterContent))
                    self$filtersAreConfiguredCorrectly <- TRUE

            self$returnContent
        },

        deleteResource = function(resource, uuid)
        {
            self$deleteResourceCallCount <- self$deleteResourceCallCount + 1
            self$returnContent
        },

        updateResource = function(resource, uuid, newContent)
        {
            self$updateResourceCallCount <- self$updateResourceCallCount + 1

            if(!is.null(self$returnContent) && !is.null(newContent))
               if(all.equal(newContent, self$returnContent))
                    self$bodyIsConfiguredCorrectly <- TRUE

            self$returnContent
        },

        createResource = function(resource, content)
        {
            self$createResourceCallCount <- self$createResourceCallCount + 1

            if(!is.null(self$returnContent) && !is.null(content))
               if(all.equal(content, self$returnContent))
                    self$bodyIsConfiguredCorrectly <- TRUE

            self$returnContent
        },

        create = function(files, uuid)
        {
            self$createCallCount <- self$createCallCount + 1
            self$returnContent
        },

        delete = function(relativePath, uuid)
        {
            self$deleteCallCount <- self$deleteCallCount + 1
            self$returnContent
        },

        move = function(from, to, uuid)
        {
            self$moveCallCount <- self$moveCallCount + 1
            self$returnContent
        },

        getCollectionContent = function(uuid)
        {
            self$getCollectionContentCallCount <- self$getCollectionContentCallCount + 1
            self$collectionContent
        },

        getResourceSize = function(uuid, relativePathToResource)
        {
            self$getResourceSizeCallCount <- self$getResourceSizeCallCount + 1
            self$returnContent
        },
        
        read = function(relativePath, uuid, contentType = "text", offset = 0, length = 0)
        {
            self$readCallCount <- self$readCallCount + 1
            self$returnContent
        },

        write = function(uuid, relativePath, content, contentType)
        {
            self$writeBuffer <- content
            self$writeCallCount <- self$writeCallCount + 1
            self$returnContent
        },

        getConnection = function(relativePath, uuid, openMode)
        {
            self$getConnectionCallCount <- self$getConnectionCallCount + 1
            self$returnContent
        }
    ),

    cloneable = FALSE
)
