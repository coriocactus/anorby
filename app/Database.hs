{-# LANGUAGE OverloadedStrings #-}

module Database where

import qualified Control.Monad as Monad
import qualified Data.Aeson as JSON
import qualified Data.ByteString.Lazy as BSL
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Map.Strict as StrictMap
import qualified Data.Maybe as Maybe
import qualified Data.Pool as Pool
import qualified Data.Text as T
import qualified Data.Time.Clock.POSIX as POSIXTime
import qualified Data.Word as Word
import qualified Database.SQLite.Simple as SQL

import Types
import Utils.Config

-- | Database initialization and connection management

initDB :: FilePath -> Bool -> IO SQL.Connection
initDB db clean = do
  conn <- SQL.open db
  Monad.when clean $ do
    putStrLn "Cleaning existing database..."
    let cleanupQueries =
          [ "PRAGMA writable_schema = 1"
          , "DELETE FROM sqlite_master"
          , "PRAGMA writable_schema = 0"
          , "VACUUM"
          , "PRAGMA integrity_check"
          ]
    mapM_ (SQL.execute_ conn . SQL.Query . T.pack) cleanupQueries
    initTables conn
    ingestBaseAorbData conn
    ingestStereoData conn
  initSQLitePragmas conn
  return conn

initConn :: FilePath -> IO SQL.Connection
initConn db = SQL.open db

initPool :: FilePath -> IO (Pool.Pool SQL.Connection)
initPool db = Pool.newPool $
  Pool.setNumStripes (Just 100) $
    Pool.defaultPoolConfig (initConn db) SQL.close 60 100

-- | SQLite optimization settings
initSQLitePragmas :: SQL.Connection -> IO ()
initSQLitePragmas conn = do
  putStrLn "Initializing SQLite pragmas for performance optimization..."
  let pragmaSettings =
        [ "PRAGMA journal_mode = WAL"
        , "PRAGMA encoding = 'UTF-8'"
        , "PRAGMA synchronous = NORMAL"
        , "PRAGMA busy_timeout = 5000"
        , "PRAGMA cache_size = -2000000"
        , "PRAGMA foreign_keys = ON"
        , "PRAGMA auto_vacuum = INCREMENTAL"
        , "PRAGMA temp_store = MEMORY"
        , "PRAGMA mmap_size = 2147483648"
        , "PRAGMA page_size = 8192"
        ]
  mapM_ (SQL.execute_ conn) pragmaSettings

  putStrLn "Verifying SQLite settings:"
  let pragmas =
        [ "journal_mode"     -- TEXT
        , "encoding"         -- TEXT
        , "synchronous"      -- INTEGER
        , "busy_timeout"     -- INTEGER
        , "cache_size"       -- INTEGER
        , "foreign_keys"     -- INTEGER
        , "auto_vacuum"      -- INTEGER
        , "temp_store"       -- INTEGER
        , "mmap_size"        -- INTEGER
        , "page_size"        -- INTEGER
        ]
  Monad.forM_ pragmas $ \pragma -> do
    let query = SQL.Query $ "PRAGMA " <> T.pack pragma
    case pragma of
      "journal_mode" -> do
        [SQL.Only value] <- SQL.query_ conn query :: IO [SQL.Only T.Text]
        putStrLn $ pragma <> " = " <> T.unpack value
      "encoding" -> do
        [SQL.Only value] <- SQL.query_ conn query :: IO [SQL.Only T.Text]
        putStrLn $ pragma <> " = " <> T.unpack value
      _ -> do
        [SQL.Only value] <- SQL.query_ conn query :: IO [SQL.Only Int]
        putStrLn $ pragma <> " = " <> show value

-- | Table initialization

initTables :: SQL.Connection -> IO ()
initTables conn = SQL.withTransaction conn $ do
  initUserTable conn
  initAorbTable conn
  initAorbAnswersTable conn
  initAorbMeanTrigger conn
  initStereoTable conn
  initAuthTable conn
  initMatchedTable conn
  initUnmatchedTable conn
  initGuessesTable conn
  initStereoGuessesTable conn
  initMessagesTable conn
  initIndexes conn

initIndexes :: SQL.Connection -> IO ()
initIndexes conn = do

  -- relatively low write volume
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_auth_hash ON auth(hash)"
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_auth_user ON auth(user_id)"

  -- low write volume table
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)"
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_users_uuid ON users(uuid)"

  -- high write volume
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_answers_user_recent ON aorb_answers(user_id, answered_on DESC)"

  -- medium write volume during matching events
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_matched_user ON matched(user_id)"
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_matched_user_time ON matched(user_id, matched_on DESC)"

  -- low write volume
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_unmatched_since ON unmatched_users(unmatched_since)"

  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_messages_match ON messages(match_id)"
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id)"
  SQL.execute_ conn $ SQL.Query
    "CREATE INDEX IF NOT EXISTS idx_messages_read ON messages(is_read)"

initAuthTable :: SQL.Connection -> IO ()
initAuthTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS auth"
  , "(id INTEGER PRIMARY KEY,"
  , "user_id INTEGER NOT NULL,"
  , "hash TEXT NOT NULL,"
  , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "last_accessed INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "FOREIGN KEY (user_id) REFERENCES users(id),"
  , "UNIQUE(hash))"
  ]

initUserTable :: SQL.Connection -> IO()
initUserTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
 [ "CREATE TABLE IF NOT EXISTS users"
 , "(id INTEGER PRIMARY KEY,"
 , "name TEXT NOT NULL,"
 , "email TEXT NOT NULL,"
 , "uuid TEXT NOT NULL,"
 , "aorb_id INTEGER,"
 , "assoc INTEGER,"
 , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
 , "UNIQUE(email),"
 , "UNIQUE(uuid))"
 ]

initAorbTable :: SQL.Connection -> IO()
initAorbTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
 [ "CREATE TABLE IF NOT EXISTS aorb"
 , "(id INTEGER PRIMARY KEY,"
 , "context TEXT NOT NULL,"
 , "subtext TEXT NOT NULL,"
 , "a TEXT NOT NULL,"
 , "b TEXT NOT NULL,"
 , "mean REAL NOT NULL DEFAULT 0.500000000000000,"
 , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')))"
 ]

initAorbAnswersTable :: SQL.Connection -> IO()
initAorbAnswersTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
 [ "CREATE TABLE IF NOT EXISTS aorb_answers"
 , "(user_id INTEGER NOT NULL,"
 , "aorb_id INTEGER NOT NULL,"
 , "answer INTEGER NOT NULL,"
 , "answered_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
 , "FOREIGN KEY (user_id) REFERENCES users(id),"
 , "FOREIGN KEY (aorb_id) REFERENCES aorb(id),"
 , "UNIQUE(user_id, aorb_id))"
 ]

initMatchedTable :: SQL.Connection -> IO ()
initMatchedTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS matched"
  , "(id INTEGER PRIMARY KEY,"
  , "user_id INTEGER NOT NULL,"
  , "target_id INTEGER NOT NULL,"
  , "matched_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "FOREIGN KEY (user_id) REFERENCES users(id),"
  , "FOREIGN KEY (target_id) REFERENCES users(id))"
  ]

initUnmatchedTable :: SQL.Connection -> IO ()
initUnmatchedTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS unmatched_users"
  , "(user_id INTEGER PRIMARY KEY,"
  , "unmatched_since INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "FOREIGN KEY (user_id) REFERENCES users(id))"
  ]

initGuessesTable :: SQL.Connection -> IO ()
initGuessesTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS guesses"
  , "(id INTEGER PRIMARY KEY,"
  , "match_id INTEGER NOT NULL,"
  , "user_id INTEGER NOT NULL,"
  , "aorb_id INTEGER NOT NULL,"
  , "guess INTEGER NOT NULL,"
  , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "FOREIGN KEY (match_id) REFERENCES matched(id),"
  , "FOREIGN KEY (user_id) REFERENCES users(id),"
  , "FOREIGN KEY (aorb_id) REFERENCES aorb(id),"
  , "UNIQUE(match_id, user_id, aorb_id))"
  ]

initStereoTable :: SQL.Connection -> IO()
initStereoTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
 [ "CREATE TABLE IF NOT EXISTS stereo"
 , "(id INTEGER PRIMARY KEY,"
 , "context TEXT NOT NULL,"
 , "subtext TEXT NOT NULL,"
 , "a TEXT NOT NULL,"
 , "b TEXT NOT NULL,"
 , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')))"
 ]

initStereoGuessesTable :: SQL.Connection -> IO ()
initStereoGuessesTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS stereo_guesses"
  , "(id INTEGER PRIMARY KEY,"
  , "match_id INTEGER NOT NULL,"
  , "user_id INTEGER NOT NULL,"
  , "target_id INTEGER NOT NULL,"
  , "stereo_id INTEGER NOT NULL,"
  , "guess INTEGER NOT NULL,"
  , "created_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "FOREIGN KEY (match_id) REFERENCES matched(id),"
  , "FOREIGN KEY (user_id) REFERENCES users(id),"
  , "FOREIGN KEY (target_id) REFERENCES users(id),"
  , "FOREIGN KEY (stereo_id) REFERENCES stereo(id),"
  , "UNIQUE(match_id, user_id, stereo_id))"
  ]

initMessagesTable :: SQL.Connection -> IO ()
initMessagesTable conn = SQL.execute_ conn $ SQL.Query $ T.unwords
  [ "CREATE TABLE IF NOT EXISTS messages"
  , "(id INTEGER PRIMARY KEY,"
  , "match_id INTEGER NOT NULL,"
  , "sender_id INTEGER NOT NULL,"
  , "content TEXT NOT NULL,"
  , "sent_on INTEGER NOT NULL DEFAULT (unixepoch('now')),"
  , "is_read INTEGER NOT NULL DEFAULT 0,"
  , "FOREIGN KEY (match_id) REFERENCES matched(id),"
  , "FOREIGN KEY (sender_id) REFERENCES users(id))"
  ]

initAorbMeanTrigger :: SQL.Connection -> IO ()
initAorbMeanTrigger conn = do
  SQL.execute_ conn $ SQL.Query $ T.unwords
    [ "CREATE TRIGGER IF NOT EXISTS update_aorb_mean_insert"
    , "AFTER INSERT ON aorb_answers BEGIN"
    , "  UPDATE aorb"
    , "  SET mean = COALESCE((SELECT AVG(answer)"
    , "                       FROM aorb_answers"
    , "                       WHERE aorb_id = NEW.aorb_id"
    , "                       AND user_id != -1),"
    , "                      0.500000000000000)"
    , "  WHERE id = NEW.aorb_id;"
    , "END"
    ]
  SQL.execute_ conn $ SQL.Query $ T.unwords
    [ "CREATE TRIGGER IF NOT EXISTS update_aorb_mean_update"
    , "AFTER UPDATE ON aorb_answers BEGIN"
    , "  UPDATE aorb"
    , "  SET mean = COALESCE((SELECT AVG(answer)"
    , "                       FROM aorb_answers"
    , "                       WHERE aorb_id = NEW.aorb_id"
    , "                       AND user_id != -1),"
    , "                      0.500000000000000)"
    , "  WHERE id = NEW.aorb_id;"
    , "END"
    ]
  SQL.execute_ conn $ SQL.Query $ T.unwords
    [ "CREATE TRIGGER IF NOT EXISTS update_aorb_mean_delete"
    , "AFTER DELETE ON aorb_answers BEGIN"
    , "  UPDATE aorb"
    , "  SET mean = COALESCE((SELECT AVG(answer)"
    , "                       FROM aorb_answers"
    , "                       WHERE aorb_id = OLD.aorb_id"
    , "                       AND user_id != -1),"
    , "                      0.500000000000000)"
    , "  WHERE id = OLD.aorb_id;"
    , "END"
    ]

migrateDatabase :: Config -> SQL.Connection -> IO ()
migrateDatabase config conn = Monad.when (shouldMigrate config) $ do
  putStrLn "Running database migrations..."
  initSQLitePragmas conn
  recreateIndexes conn
  recreateTriggers conn
  putStrLn "Database migrations completed."

recreateIndexes :: SQL.Connection -> IO ()
recreateIndexes conn = do
  putStrLn "Recreating indexes..."
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_auth_hash"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_auth_user"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_users_email"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_users_uuid"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_answers_user_recent"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_matched_user"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_matched_user_time"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_unmatched_since"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_messages_match"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_messages_sender"
  SQL.execute_ conn "DROP INDEX IF EXISTS idx_messages_read"
  initIndexes conn
  putStrLn "Indexes recreated."

recreateTriggers :: SQL.Connection -> IO ()
recreateTriggers conn = do
  putStrLn "Recreating triggers..."
  SQL.execute_ conn "DROP TRIGGER IF EXISTS update_aorb_mean_insert"
  SQL.execute_ conn "DROP TRIGGER IF EXISTS update_aorb_mean_update"
  SQL.execute_ conn "DROP TRIGGER IF EXISTS update_aorb_mean_delete"
  initAorbMeanTrigger conn
  putStrLn "Triggers recreated."

-- | Base data management

readBaseAorbs :: IO (Maybe [Aorb])
readBaseAorbs = do
  jsonData <- BSL.readFile "data/base.json"
  return $ JSON.decode jsonData

ingestBaseAorbData :: SQL.Connection -> IO ()
ingestBaseAorbData conn = do
  base <- readBaseAorbs
  case base of
    Just aorbs -> SQL.withTransaction conn $ SQL.executeMany conn
      (SQL.Query $ T.unwords
            [ "INSERT OR REPLACE INTO aorb (id, context, subtext, a, b)"
            , "VALUES (?, ?, ?, ?, ?)"
            ]
      ) (map (\aorb -> (aorbId aorb, aorbCtx aorb, aorbStx aorb, aorbA aorb, aorbB aorb)) aorbs)
    Nothing -> putStrLn "error parsing base.json"

readStereoQuestions :: IO (Maybe [Stereo])
readStereoQuestions = do
  jsonData <- BSL.readFile "data/stereo.json"
  return $ JSON.decode jsonData

ingestStereoData :: SQL.Connection -> IO ()
ingestStereoData conn = do
  stereo <- readStereoQuestions
  case stereo of
    Just questions -> SQL.withTransaction conn $ SQL.executeMany conn
      (SQL.Query $ T.unwords
            [ "INSERT OR REPLACE INTO stereo (id, context, subtext, a, b)"
            , "VALUES (?, ?, ?, ?, ?)"
            ]
      ) (map (\q -> (stereoId q, stereoCtx q, stereoStx q, stereoA q, stereoB q)) questions)
    Nothing -> putStrLn "error parsing stereo.json"

-- | User query functions

getUserByUuid :: SQL.Connection -> T.Text -> IO (Maybe User)
getUserByUuid conn uuid = do
  users <- SQL.query
      conn "SELECT * FROM users WHERE uuid = ?" (SQL.Only uuid) :: IO [User]
  return $ case users of
    [user] -> Just user
    _ -> Nothing

getUserUuidById :: SQL.Connection -> UserID -> IO (Maybe T.Text)
getUserUuidById conn uid = do
  let query = "SELECT uuid FROM users WHERE id = ?"
  results <- SQL.query conn query (SQL.Only uid) :: IO [SQL.Only T.Text]
  return $ case results of
    [SQL.Only uuid] -> Just uuid
    _ -> Nothing

getUserTotalAnswerCount :: SQL.Connection -> UserID -> IO Int
getUserTotalAnswerCount conn uid = do
  let query = SQL.Query "SELECT COUNT(*) FROM aorb_answers WHERE user_id = ?"
  counts <- SQL.query conn query [uid] :: IO [SQL.Only Int]
  case counts of
    (count:_) -> return $ SQL.fromOnly count
    [] -> return 0

hasThresholdAccess :: SQL.Connection -> UserID -> Int -> IO Bool
hasThresholdAccess conn uid threshold = do
  count <- getUserTotalAnswerCount conn uid
  return $ count >= threshold

getUserFromAuthHash :: SQL.Connection -> T.Text -> IO (Maybe User)
getUserFromAuthHash conn hash = do
  let query = SQL.Query "SELECT users.* FROM users JOIN auth ON users.id = auth.user_id WHERE auth.hash = ?"
  results <- SQL.query conn query (SQL.Only hash) :: IO [User]
  case results of
    [user] -> do
      SQL.execute conn
        "UPDATE auth SET last_accessed = unixepoch('now') WHERE hash = ?"
        (SQL.Only hash)
      return $ Just user
    _ -> return Nothing

-- | Aggregate users query functions

getUsersWithCompletedAnswers :: SQL.Connection -> IO [UserID]
getUsersWithCompletedAnswers conn = do
  dailyLimitUsers <- SQL.query_ conn $ SQL.Query $ T.unwords
      [ "SELECT DISTINCT user_id"
      , "FROM aorb_answers"
      , "WHERE date(datetime(CAST(SUBSTR(answered_on, 1, "
      , "      CASE WHEN INSTR(answered_on, 's') > 0"
      , "           THEN INSTR(answered_on, 's') - 1"
      , "           ELSE LENGTH(answered_on)"
      , "      END) AS FLOAT), 'unixepoch')) = date('now')"
      , "GROUP BY user_id"
      , "HAVING COUNT(*) >= 10"
      ]
  allQuestionsUsers <- SQL.query_ conn $ SQL.Query $ T.unwords
    [ "SELECT DISTINCT aa.user_id"
    , "FROM aorb_answers aa"
    , "GROUP BY aa.user_id"
    , "HAVING COUNT(DISTINCT aa.aorb_id) = ("
    , "  SELECT COUNT(*)"
    , "  FROM aorb"
    , ")"
    ]
  let dailyLimitIds =
        map SQL.fromOnly (dailyLimitUsers :: [SQL.Only UserID])
      allQuestionsIds =
        map SQL.fromOnly (allQuestionsUsers :: [SQL.Only UserID])
  return $ List.nub $ dailyLimitIds ++ allQuestionsIds

getUsersWithAnswers :: SQL.Connection -> [AorbID] -> IO [UserID]
getUsersWithAnswers conn aorbIds = do
  let placeholders = replicate (length aorbIds) "?"
      inClause = T.intercalate "," placeholders
      query = SQL.Query $ T.unwords
        [ "SELECT user_id"
        , "FROM aorb_answers"
        , "WHERE aorb_id IN (" <> inClause <> ")"
        , "GROUP BY user_id"
        , "HAVING COUNT(DISTINCT aorb_id) = ?"
        ]
      params = aorbIds ++ [length aorbIds]
  users <- SQL.query conn query params :: IO [SQL.Only UserID]
  return $ map SQL.fromOnly users

getUsersAnswers :: SQL.Connection -> [UserID] -> [AorbID] -> IO (Map.Map UserID [AorbAnswers])
getUsersAnswers conn users aorbIds = do
  existingAnswers <- if null users || null aorbIds
    then return []
    else SQL.query conn query (users ++ aorbIds) :: IO [AorbAnswers]
  let existingMap = Map.fromList
        [ ((aorbUserId ans, aorbAorbId ans), ans)
        | ans <- existingAnswers
        ]
      defaultAnswer uid aid = AorbAnswers
        { aorbUserId = uid
        , aorbAorbId = aid
        , aorbAnswer = AorbAnswer 255
        , aorbAnsweredOn = 0
        }
      allPairs = [(user, aorb) | user <- users, aorb <- aorbIds]
      answers =
        [ maybe (defaultAnswer user aorb) id $
            Map.lookup (user, aorb) existingMap
        | (user, aorb) <- allPairs
        ]
  return $ Map.fromListWith (++)
    [ (uid, [ans]) | ans <- answers , let uid = aorbUserId ans ]
  where
    query = SQL.Query $ T.unwords
      [ "SELECT user_id, aorb_id, answer, answered_on"
      , "FROM aorb_answers"
      , "WHERE user_id IN (" <> placeholders (length users) <> ")"
      , "AND aorb_id IN (" <> placeholders (length aorbIds) <> ")"
      ]
    placeholders n = T.intercalate "," (replicate n "?")

getUsersAorbIdAndAssoc :: SQL.Connection -> [UserID] -> IO (Map.Map UserID (AorbID, AssociationScheme))
getUsersAorbIdAndAssoc conn users = do
  let placeholders = replicate (length users) "?"
      inClause = T.intercalate "," placeholders
      query = SQL.Query $ T.unwords
        [ "SELECT id, COALESCE(aorb_id, 1), assoc"
        , "FROM users"
        , "WHERE id IN (" <> inClause <> ")"
        ]
  aorbs <- SQL.query
    conn query users :: IO [(UserID, AorbID, AssociationScheme)]
  return $ Map.fromList [(uid, (aid, assoc)) | (uid, aid, assoc) <- aorbs]

-- | Submissions functions

baseAorbsToSubmissions :: SQL.Connection -> IO Submissions
baseAorbsToSubmissions conn = do
  aorbIds <- SQL.query_ conn "SELECT id FROM aorb" :: IO [SQL.Only AorbID]
  let count_aorbs = length aorbIds
  basedUsers <- getUsersWithAnswers conn [1..count_aorbs]
  basedUsersAnswers <- getUsersAnswers conn basedUsers [1..count_aorbs]
  basedUsersAorbIdAssoc <- getUsersAorbIdAndAssoc conn basedUsers
  return $ Map.mapWithKey (\uid (aid, assoc) ->
    let answers =
          maybe [] (map aorbAnswer) $ Map.lookup uid basedUsersAnswers
    in (answers, aid, assoc)
    ) basedUsersAorbIdAssoc

allAorbsToSubmissions :: SQL.Connection -> [UserID] -> IO Submissions
allAorbsToSubmissions conn users = do
  aorbIds <- SQL.query_ conn
    "SELECT id FROM aorb ORDER BY id" :: IO [SQL.Only AorbID]
  let aorbIdList = map SQL.fromOnly aorbIds
  usersAnswers <- getUsersAnswers conn users aorbIdList
  usersAorbIdAssoc <- getUsersAorbIdAndAssoc conn users
  return $ Map.mapWithKey (\uid (aid, assoc) ->
    let answers = maybe [] (map aorbAnswer) $ Map.lookup uid usersAnswers
    in (answers, aid, assoc)
    ) usersAorbIdAssoc

-- | Match query functions

getUserMatches :: SQL.Connection -> UserID -> IO [Match]
getUserMatches conn uid = do
  let query = SQL.Query $ T.unwords
        [ "SELECT user_id, target_id, matched_on"
        , "FROM matched"
        , "WHERE user_id = ?"
        , "ORDER BY matched_on DESC"
        ]
  SQL.query conn query [uid]

getRecentMatchMap :: SQL.Connection -> [UserID] -> IO [(UserID, [UserID])]
getRecentMatchMap conn userIds = do
  now <- POSIXTime.getPOSIXTime
  let recency = floor now - (28 * 24 * 60 * 60) :: Integer
  matches <- Monad.forM userIds $ \uid -> do
    recentMatches <- SQL.query conn
      (SQL.Query $ T.unwords
        [ "SELECT target_id"
        , "FROM matched"
        , "WHERE user_id = ?"
        , "AND matched_on > ?"
        , "ORDER BY matched_on DESC"
        ]) (uid, recency)
    return (uid, map SQL.fromOnly recentMatches)
  return matches

getMatchBetweenUsers :: SQL.Connection -> UserID -> UserID -> IO (Maybe Match)
getMatchBetweenUsers conn uid1 uid2 = do
  let query = SQL.Query $ T.unwords
        [ "SELECT user_id, target_id, matched_on"
        , "FROM matched"
        , "WHERE (user_id = ? AND target_id = ?)"
        , "ORDER BY matched_on DESC"
        , "LIMIT 1"
        ]
  matches <- SQL.query conn query (uid1, uid2) :: IO [Match]
  return $ case matches of
    (match:_) -> Just match
    [] -> Nothing

-- | Match ingestion functions

insertMatches :: SQL.Connection -> Marriages -> IO ()
insertMatches conn marriages = do
  let matches = marriagesToMatches marriages
  SQL.withTransaction conn $ do
    SQL.executeMany conn "INSERT INTO matched (user_id, target_id) VALUES (?, ?)" matches

marriagesToMatches :: Marriages -> [(UserID, UserID)]
marriagesToMatches marriages =
  [ (uid, tid)
  | (uid, Just tid) <- StrictMap.toList marriages
  , uid < tid
  ] >>= makeSymmetric
  where
    makeSymmetric (p1, p2) = [(p1, p2), (p2, p1)]

-- | Aorb query functions

getNextUnansweredAorb :: SQL.Connection -> UserID -> IO (Maybe Aorb)
getNextUnansweredAorb conn uid = do
  baseAorb <- getUnansweredAorbWhere conn uid "a.id <= 100"
  case baseAorb of
    Just aorb -> return $ Just aorb
    Nothing -> getUnansweredAorbWhere conn uid "a.id > 100"
  where
    getUnansweredAorbWhere :: SQL.Connection -> UserID -> T.Text
                           -> IO (Maybe Aorb)
    getUnansweredAorbWhere c u condition = do
      let query = SQL.Query $ T.unwords
            [ "SELECT a.*"
            , "FROM aorb a"
            , "WHERE " <> condition
            , "AND NOT EXISTS ("
            , "  SELECT 1"
            , "  FROM aorb_answers ans"
            , "  WHERE ans.aorb_id = a.id"
            , "  AND ans.user_id = ?"
            , ")"
            , "ORDER BY a.id"
            , "LIMIT 1"
            ]
      results <- SQL.query c query [u] :: IO [Aorb]
      return $ case results of
        (x:_) -> Just x
        [] -> Nothing

getDailyAnswerCount :: SQL.Connection -> UserID -> IO Int
getDailyAnswerCount conn uid = do
  now <- POSIXTime.getPOSIXTime
  let secondsInDay = floor POSIXTime.posixDayLength :: Integer
      startOfDay = floor (now / POSIXTime.posixDayLength) * secondsInDay
      endOfDay = startOfDay + secondsInDay
  let query = SQL.Query $ T.unwords
        [ "SELECT COUNT(*)"
        , "FROM aorb_answers"
        , "WHERE user_id = ?"
        , "AND answered_on >= ?"
        , "AND answered_on < ?"
        ]
  counts <- SQL.query conn query
             (uid, startOfDay, endOfDay) :: IO [SQL.Only Int]
  case counts of
    (count:_) -> return $ SQL.fromOnly count
    [] -> return 0

getUserAorbAndAssoc :: SQL.Connection -> UserID -> IO (Maybe (Aorb, AssociationScheme))
getUserAorbAndAssoc conn uid = do
  let query = "SELECT aorb_id, assoc FROM users WHERE id = ?"
  aorbIdAssoc <- SQL.query conn query [uid] :: IO [(AorbID, AssociationScheme)]
  case aorbIdAssoc of
    [(aid, assoc)] -> do
      let aorbQuery = SQL.Query $ T.unwords
                    [ "SELECT id, context, subtext, a, b, mean, created_on"
                    , "FROM aorb"
                    , "WHERE id = ?"
                    ]
      aorb <- SQL.query conn aorbQuery [aid] :: IO [Aorb]
      case aorb of
        [aorb'] -> return $ Just (aorb', assoc)
        _ -> return Nothing
    [] -> return Nothing
    _ -> return Nothing

getUserTopXMostCommonplace :: SQL.Connection -> UserID -> Int -> IO [AorbWithAnswer]
getUserTopXMostCommonplace conn uid x = do
  let query = SQL.Query $ T.unwords
        [ "SELECT a.id, a.context, a.subtext, a.a, a.b, a.mean, a.created_on, ans.answer"
        , "FROM aorb a"
        , "JOIN aorb_answers ans ON a.id = ans.aorb_id"
        , "WHERE ans.user_id = ?"
        , "ORDER BY ABS(CAST(ans.answer AS REAL) - a.mean) ASC"
        , "LIMIT ?"
        ]
  SQL.query conn query (uid, x)

getUserTopXMostControversial :: SQL.Connection -> UserID -> Int -> IO [AorbWithAnswer]
getUserTopXMostControversial conn uid x = do
  let query = SQL.Query $ T.unwords
        [ "SELECT a.id, a.context, a.subtext, a.a, a.b, a.mean, a.created_on, ans.answer"
        , "FROM aorb a"
        , "JOIN aorb_answers ans ON a.id = ans.aorb_id"
        , "WHERE ans.user_id = ?"
        , "ORDER BY ABS(CAST(ans.answer AS REAL) - a.mean) DESC"
        , "LIMIT ?"
        ]
  SQL.query conn query (uid, x)

getUserAorbsFromControversialToCommonPlace :: SQL.Connection -> UserID -> IO [AorbWithAnswer]
getUserAorbsFromControversialToCommonPlace conn uid = do
  let query = SQL.Query $ T.unwords
        [ "SELECT a.id, a.context, a.subtext, a.a, a.b, a.mean, a.created_on, ans.answer"
        , "FROM aorb a"
        , "JOIN aorb_answers ans ON a.id = ans.aorb_id"
        , "WHERE ans.user_id = ?"
        , "ORDER BY ABS(CAST(ans.answer AS REAL) - a.mean) DESC"
        ]
  SQL.query conn query [uid]

getMatchesMainAorbs :: SQL.Connection -> UserID -> UserID -> IO (Maybe (MatchingAorbWithAnswer, MatchingAorbWithAnswer))
getMatchesMainAorbs conn uid1 uid2 = do
  let userQuery = SQL.Query "SELECT aorb_id FROM users WHERE id IN (?, ?)"
  aorbIds <- SQL.query conn userQuery (uid1, uid2) :: IO [SQL.Only Int]
  case aorbIds of
    [SQL.Only aid1, SQL.Only aid2] -> do
      let aorbQuery = SQL.Query $ T.unwords
            [ "SELECT a.id, a.context, a.subtext, a.a, a.b, a.mean, a.created_on,"
            , "ans1.answer as user1_answer,"
            , "ans2.answer as user2_answer"
            , "FROM aorb a"
            , "JOIN aorb_answers ans1"
            , "ON a.id = ans1.aorb_id AND ans1.user_id = ?"
            , "JOIN aorb_answers ans2"
            , "ON a.id = ans2.aorb_id AND ans2.user_id = ?"
            , "WHERE a.id = ?"
            ]
      aorb1s <- SQL.query
        conn aorbQuery (uid1, uid2, aid1) :: IO [MatchingAorbWithAnswer]
      aorb2s <- SQL.query
        conn aorbQuery (uid1, uid2, aid2) :: IO [MatchingAorbWithAnswer]
      case (aorb1s, aorb2s) of
        ([a1], [a2]) -> return $ Just (a1, a2)
        _ -> return Nothing
    _ -> return Nothing

getMatchesTopXCommonDisagreement :: SQL.Connection -> UserID -> UserID -> Int -> IO [MatchingAorbWithAnswer]
getMatchesTopXCommonDisagreement conn uid1 uid2 x = do
  let query = SQL.Query $ T.unwords
        [ "WITH disagreements AS ("
        , "  SELECT b.id, b.context, b.subtext, b.a, b.b, b.mean, b.created_on,"
        , "         a1.answer as main_answer, a2.answer as other_answer,"
        , "         mean * (1 - mean) as variance"
        , "  FROM aorb_answers a1"
        , "  JOIN aorb_answers a2 ON a1.aorb_id = a2.aorb_id"
        , "  JOIN aorb b ON a1.aorb_id = b.id"
        , "  WHERE a1.user_id = ?"
        , "  AND a2.user_id = ?"
        , "  AND a1.answer != a2.answer"
        , ")"
        , "SELECT id, context, subtext, a, b, mean, created_on, main_answer, other_answer"
        , "FROM disagreements"
        , "ORDER BY variance DESC"
        , "LIMIT ?"
        ]
  SQL.query conn query (uid1, uid2, x)

getMatchesTopXUniqueAgreement :: SQL.Connection -> UserID -> UserID -> Int -> IO [MatchingAorbWithAnswer]
getMatchesTopXUniqueAgreement conn uid1 uid2 x = do
  let query = SQL.Query $ T.unwords
        [ "WITH matching_answers AS ("
        , "  SELECT b.id, b.context, b.subtext, b.a, b.b, b.mean, b.created_on,"
        , "         a1.answer as main_answer, a2.answer as other_answer,"
        , "         ABS(a1.answer - b.mean) as difference"
        , "  FROM aorb_answers a1"
        , "  JOIN aorb_answers a2 ON a1.aorb_id = a2.aorb_id"
        , "  JOIN aorb b ON a1.aorb_id = b.id"
        , "  WHERE a1.user_id = ?"
        , "  AND a2.user_id = ?"
        , "  AND a1.answer = a2.answer"
        , ")"
        , "SELECT id, context, subtext, a, b, mean, created_on, main_answer, other_answer"
        , "FROM matching_answers"
        , "ORDER BY difference"
        , "LIMIT ?"
        ]
  SQL.query conn query (uid1, uid2, x)

getLargestIntersection :: SQL.Connection -> UserID -> UserID -> IO [AorbID]
getLargestIntersection conn uid1 uid2 = do
  let query = SQL.Query $ T.unwords
        [ "SELECT aorb_id"
        , "FROM aorb_answers"
        , "WHERE user_id = ?"
        , "INTERSECT"
        , "SELECT aorb_id"
        , "FROM aorb_answers"
        , "WHERE user_id = ?"
        ]
  rows <- SQL.query conn query (uid1, uid2) :: IO [SQL.Only AorbID]
  return $ map SQL.fromOnly rows

getLargestIntersectionAnswers :: SQL.Connection -> UserID -> UserID -> IO ([AorbAnswer], [AorbAnswer])
getLargestIntersectionAnswers conn uid1 uid2 = do
  intersection <- getLargestIntersection conn uid1 uid2
  if null intersection
    then return ([], [])
    else do
      let query =
            SQL.Query $ T.unwords
              [ "SELECT user_id, aorb_id, answer"
              , "FROM aorb_answers"
              , "WHERE user_id IN (?, ?)"
              , "AND aorb_id IN ("
              , T.intercalate "," (map (T.pack . show) intersection)
              , ")"
              , "ORDER BY aorb_id, user_id"
              ]
      rows <- SQL.query
        conn query (uid1, uid2) :: IO [(UserID, AorbID, AorbAnswer)]
      let (answers1, answers2) =
            List.partition (\(uid, _, _) -> uid == uid1) rows
      return (map (\(_, _, ans) -> ans) answers1,
              map (\(_, _, ans) -> ans) answers2)

-- | Guess query functions

getGuessAorbs :: SQL.Connection -> UserID -> [AorbID] -> Int -> IO [Aorb]
getGuessAorbs conn targetId excludeIds count = do
  let placeholders =
        if null excludeIds
          then "(-1)"
          else "(" <> T.intercalate "," (map (T.pack . show) excludeIds) <> ")"
  SQL.query conn
    (SQL.Query $ T.unwords
      [ "SELECT a.*"
      , "FROM aorb a"
      , "JOIN aorb_answers ans ON a.id = ans.aorb_id"
      , "WHERE ans.user_id = ?"
      , "AND a.id NOT IN " <> placeholders
      , "ORDER BY RANDOM()"
      , "LIMIT ?"
      ])
    (targetId, count)

saveGuess :: SQL.Connection -> Int -> UserID -> AorbID -> AorbAnswer -> IO ()
saveGuess conn matchId uid aid answer = do
  SQL.execute conn
    (SQL.Query $ T.unwords
      [ "INSERT OR REPLACE INTO guesses"
      , "(match_id, user_id, aorb_id, guess)"
      , "VALUES (?, ?, ?, ?)"
      ])
    (matchId, uid, aid, answer)

getGuesses :: SQL.Connection -> Int -> UserID -> IO [Guess]
getGuesses conn matchId uid = do
  SQL.query conn
    ( SQL.Query $ T.unwords
        [ "SELECT id, match_id, user_id, aorb_id, guess, created_on"
        , "FROM guesses"
        , "WHERE match_id = ? AND user_id = ?"
        , "ORDER BY created_on ASC"
        ]
    ) (matchId, uid)

getGuessResults :: SQL.Connection -> Int -> UserID -> UserID -> IO [GuessResult]
getGuessResults conn matchId uid targetId = do
  guesses <- SQL.query conn
    "SELECT aorb_id, guess FROM guesses WHERE match_id = ? AND user_id = ? ORDER BY created_on"
    (matchId, uid) :: IO [(AorbID, Word.Word8)]

  results <- Monad.forM guesses $ \(gAorbId, gGuess) -> do
    aorbs <- SQL.query conn
      "SELECT id, context, subtext, a, b, mean, created_on FROM aorb WHERE id = ?"
      (SQL.Only gAorbId) :: IO [Aorb]
    targetAnswers <- SQL.query conn
      "SELECT answer FROM aorb_answers WHERE user_id = ? AND aorb_id = ?"
      (targetId, gAorbId) :: IO [SQL.Only AorbAnswer]
    case (aorbs, targetAnswers) of
      ([aorb], [SQL.Only actual]) ->
        return $ Just $ GuessResult
          { guessResultAorb = aorb
          , guessResultGuess = AorbAnswer gGuess
          , guessResultActual = actual
          , guessResultCorrect = AorbAnswer gGuess == actual
          }
      _ -> return Nothing

  return $ Maybe.catMaybes results

hasAllGuessesCorrect :: SQL.Connection -> Int -> UserID -> IO Bool
hasAllGuessesCorrect conn matchId uid = do
  matchQuery <- SQL.query conn
    "SELECT user_id, target_id FROM matched WHERE id = ? AND (user_id = ? OR target_id = ?)"
    (matchId, uid, uid) :: IO [(UserID, UserID)]

  case matchQuery of
    [(u, t)] -> do
      let targetId = if u == uid then t else u
      guessResults <- getGuessResults conn matchId uid targetId
      return $ length guessResults == 3 && all guessResultCorrect guessResults
    _ -> return False

getStereoQuestions :: SQL.Connection -> Int -> IO [Stereo]
getStereoQuestions conn count = do
  SQL.query conn
    "SELECT * FROM stereo ORDER BY RANDOM() LIMIT ?"
    (SQL.Only count)

getStereoQuestionsExcluding :: SQL.Connection -> [Int] -> Int -> IO [Stereo]
getStereoQuestionsExcluding conn excludeIds count = do
  let placeholders =
        if null excludeIds
          then "(-1)"
          else "(" <> T.intercalate "," (map (T.pack . show) excludeIds) <> ")"

  SQL.query conn
    (SQL.Query $ T.unwords
      [ "SELECT *"
      , "FROM stereo"
      , "WHERE id NOT IN " <> placeholders
      , "ORDER BY RANDOM()"
      , "LIMIT ?"
      ])
    (SQL.Only count)

saveStereoGuess :: SQL.Connection -> Int -> UserID -> UserID -> Int -> AorbAnswer -> IO ()
saveStereoGuess conn matchId uid targetId sid answer = do
  SQL.execute conn
    (SQL.Query $ T.unwords
      [ "INSERT OR REPLACE INTO stereo_guesses"
      , "(match_id, user_id, target_id, stereo_id, guess)"
      , "VALUES (?, ?, ?, ?, ?)"
      ])
    (matchId, uid, targetId, sid, answer)

getStereoGuesses :: SQL.Connection -> Int -> UserID -> IO [StereoGuess]
getStereoGuesses conn matchId uid = do
  SQL.query conn
    ( SQL.Query $ T.unwords
        [ "SELECT id, match_id, user_id, target_id, stereo_id, guess, created_on"
        , "FROM stereo_guesses"
        , "WHERE match_id = ? AND user_id = ?"
        , "ORDER BY created_on ASC"
        ]
    ) (matchId, uid)

getStereoGuessesForTarget :: SQL.Connection -> Int -> UserID -> IO [StereoGuess]
getStereoGuessesForTarget conn matchId targetId = do
  SQL.query conn
    ( SQL.Query $ T.unwords
        [ "SELECT id, match_id, user_id, target_id, stereo_id, guess, created_on"
        , "FROM stereo_guesses"
        , "WHERE match_id = ? AND target_id = ?"
        , "ORDER BY created_on ASC"
        ]
    ) (matchId, targetId)

getStereoById :: SQL.Connection -> Int -> IO (Maybe Stereo)
getStereoById conn sid = do
  results <- SQL.query conn "SELECT * FROM stereo WHERE id = ?" (SQL.Only sid)
  case results of
    [stereo] -> return $ Just stereo
    _ -> return Nothing

-- | Message query functions

getMessageCount :: SQL.Connection -> Int -> UserID -> IO Int
getMessageCount conn matchId uid = do
  let query = SQL.Query $ T.unwords
        [ "SELECT COUNT(*)"
        , "FROM messages"
        , "WHERE match_id = ?"
        , "AND sender_id = ?"
        ]
  counts <- SQL.query conn query (matchId, uid) :: IO [SQL.Only Int]
  return $ maybe 0 SQL.fromOnly $ Maybe.listToMaybe counts

validateNewMessage :: Config -> SQL.Connection -> Int -> UserID -> T.Text -> IO Bool
validateNewMessage config conn matchId senderId content = do
  matchQuery <- SQL.query conn
    "SELECT user_id, target_id FROM matched WHERE id = ? AND (user_id = ? OR target_id = ?)"
    (matchId, senderId, senderId) :: IO [(UserID, UserID)]

  case matchQuery of
    [(u, t)] -> do
      let targetId = if u == senderId then t else u
      guessResults <- getGuessResults conn matchId senderId targetId
      stereoGuesses <- getStereoGuesses conn matchId senderId

      let correctGuessCount = length $ filter guessResultCorrect guessResults
          hasCompletedAllStereoGuesses = length stereoGuesses >= 3
          messageLimit = case correctGuessCount of
            0 -> 0
            1 -> 3
            2 -> 6
            3 -> 18
            _ -> 3

      if not hasCompletedAllStereoGuesses
        then return False
        else do
          messageCount <- getMessageCount conn matchId senderId
          if messageCount >= messageLimit
            then return False
            else if T.length content > matchMessageMaxLength config
              then return False
              else return True
    _ -> return False

insertMessage :: SQL.Connection -> Int -> UserID -> T.Text -> IO ()
insertMessage conn matchId senderId content = do
  SQL.execute conn
    ( SQL.Query $ T.unwords
      [ "INSERT INTO messages"
      , "(match_id, sender_id, content)"
      , "VALUES (?, ?, ?)"
      ]
    ) (matchId, senderId, content)

getMessagesForMatch :: SQL.Connection -> Int -> IO [Message]
getMessagesForMatch conn matchId =
  SQL.query conn
    "SELECT * FROM messages WHERE match_id = ? ORDER BY sent_on ASC" [matchId]

getUnreadMessageCount :: SQL.Connection -> UserID -> Match -> IO Int
getUnreadMessageCount conn uid match = do
  let query = SQL.Query $ T.unwords
        [ "SELECT COUNT(*)"
        , "FROM messages m"
        , "JOIN matched mt ON m.match_id = mt.id"
        , "WHERE mt.matched_on = ?"
        , "AND (mt.user_id = ? OR mt.target_id = ?)"
        , "AND m.sender_id != ?"
        , "AND m.is_read = 0"
        ]
  counts <- SQL.query conn query
    (matchTimestamp match, uid, uid, uid) :: IO [SQL.Only Int]
  return $ maybe 0 SQL.fromOnly $ Maybe.listToMaybe counts

markMessagesRead :: SQL.Connection -> Int -> UserID -> IO ()
markMessagesRead conn matchId receiverId = do
  SQL.execute conn
    "UPDATE messages SET is_read = 1 WHERE match_id = ? AND sender_id != ?"
    (matchId, receiverId)

cleanupExpiredMessages :: Config -> SQL.Connection -> IO ()
cleanupExpiredMessages config conn = do
  now <- POSIXTime.getPOSIXTime
  let expiryAgo = floor now - (matchExpiryDays config * 24 * 60 * 60)
      query = SQL.Query $ T.unwords
        [ "DELETE FROM messages"
        , "WHERE match_id IN (SELECT id FROM matched WHERE matched_on < ?)"
        ]
  SQL.execute conn query (SQL.Only expiryAgo)
