## Shared data model for the submission.
##
## These values mirror the feed row and API payload. Text is stored already
## decoded and trimmed; the DB layer does the JSON escaping when it writes a
## response, so a `Post` never carries pre-escaped JSON.

type Post* = object
  ## One feed row, as returned by the query layer.
  id*: int64           ## database row id
  body*: string        ## already trimmed (as stored / wire text)
  createdAt*: string   ## "YYYY-MM-DDTHH:MM:SS.mmmZ"
  author*: string      ## owning user's display name
  likeCount*: int64    ## total likes, including the current viewer
