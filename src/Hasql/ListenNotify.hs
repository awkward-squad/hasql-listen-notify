module Hasql.ListenNotify
  ( -- * Listen

    -- ** Listen
    listen,
    unlisten,
    unlistenAll,

    -- ** Await
    Notification (..),
    await,
    poll,
    backendPid,

    -- * Notify
    Notify (..),
    notify,
    notify2,
  )
where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class
import Control.Monad.Reader (ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as ByteString.Builder
import qualified Data.ByteString.Builder.Prim as ByteString.Builder.Prim
import qualified Data.ByteString.Lazy as ByteString.Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import GHC.Conc.IO (threadWaitRead, threadWaitWrite)
import qualified Hasql.Connection as Connection
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import Hasql.Session (Session)
import qualified Hasql.Session as Session
import Hasql.Statement (Statement (..))
import System.Posix.Types (CPid)

-- | Listen to a channel.
--
-- https://www.postgresql.org/docs/current/sql-listen.html
listen :: Text -> Statement () ()
listen chan =
  Statement sql Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString
    sql =
      builderToByteString ("LISTEN \"" <> escapeIdentifier chan <> "\"")

-- | Stop listening to a channel.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlisten :: Text -> Statement () ()
unlisten chan =
  Statement sql Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString
    sql =
      builderToByteString ("UNLISTEN \"" <> escapeIdentifier chan <> "\"")

-- | Stop listening to all channels.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlistenAll :: Statement () ()
unlistenAll =
  Statement "UNLISTEN *" Encoders.noParams Decoders.noResult False

-- | An incoming notification.
data Notification = Notification
  { channel :: !Text,
    payload :: !Text,
    pid :: !CPid
  }

-- | Get the next notification received from the server.
--
-- https://www.postgresql.org/docs/current/libpq-notify.html
await :: Session Notification
await =
  libpq await_ >>= \case
    Left err -> throwError err
    Right notification -> pure (parseNotification notification)

await_ :: LibPQ.Connection -> IO (Either Session.QueryError LibPQ.Notify)
await_ conn =
  pollForNotification
  where
    pollForNotification :: IO (Either Session.QueryError LibPQ.Notify)
    pollForNotification =
      LibPQ.notifies conn >>= \case
        -- Block until a notification arrives. Snag: the connection might be closed (what). If so, attempt to reset it
        -- and poll for a notification on the new connection.
        Nothing ->
          LibPQ.socket conn >>= \case
            -- "No connection is currently open"
            Nothing -> do
              LibPQ.resetStart conn >>= \case
                False -> queryError
                True -> do
                  -- Assuming single-threaded access to the connection, which is the only sane way to use a connection,
                  -- `PQsocket` can't fail after a successful `PQresetStart`.
                  Just socket <- LibPQ.socket conn
                  let pollForConnection :: LibPQ.PollingStatus -> IO (Either Session.QueryError LibPQ.Notify)
                      pollForConnection = \case
                        LibPQ.PollingFailed -> queryError
                        LibPQ.PollingOk -> pollForNotification
                        LibPQ.PollingReading -> do
                          threadWaitRead socket
                          pollForConnectionAgain
                        LibPQ.PollingWriting -> do
                          threadWaitWrite socket
                          pollForConnectionAgain
                      pollForConnectionAgain :: IO (Either Session.QueryError LibPQ.Notify)
                      pollForConnectionAgain = do
                        status <- LibPQ.resetPoll conn
                        pollForConnection status
                  -- "On the first iteration, i.e., if you have yet to call PQconnectPoll, behave as if it last returned
                  -- PGRES_POLLING_WRITING."
                  pollForConnection LibPQ.PollingWriting
            Just socket -> do
              threadWaitRead socket
              -- Data has appeared on the socket, but libPQ won't buffer it for us unless we do something (PQexec, etc).
              -- PQconsumeInput is provided for when we don't have anything to do except populate the notification
              -- buffer. But it can fail, which is weird; just propagate those failures as query errors.
              LibPQ.consumeInput conn >>= \case
                False -> queryError
                True -> pollForNotification
        Just notification -> pure (Right notification)

    queryError :: IO (Either Session.QueryError a)
    queryError = do
      message <- LibPQ.errorMessage conn
      pure (Left (Session.QueryError "PQnotifies()" [] (Session.ClientError message)))

-- | Variant of 'await' that doesn't block.
poll :: Session (Maybe Notification)
poll =
  libpq \conn -> fmap parseNotification <$> LibPQ.notifies conn

-- | Get the PID of the backend process handling this session. This can be used to filter out notifications that
-- originate from this session.
--
-- https://www.postgresql.org/docs/current/libpq-status.html
backendPid :: Session CPid
backendPid =
  libpq LibPQ.backendPID

-- | An outgoing notification.
data Notify = Notify
  { channel :: !Text,
    payload :: !Text
  }

-- | Notify a channel.
--
-- https://www.postgresql.org/docs/current/sql-notify.html
notify :: Text -> Statement Text ()
notify chan =
  Statement sql encoder Decoders.noResult True
  where
    sql :: ByteString
    sql =
      builderToByteString ("NOTIFY \"" <> escapeIdentifier chan <> "\", $1")

    encoder :: Encoders.Params Text
    encoder =
      Encoders.param (Encoders.nonNullable Encoders.text)

-- | Variant of 'notify' that prepares a query with a parameter for the channel.
--
-- You may prefer this variant if you have a large number of channels to notify and don't want to prepare a separate
-- query for each one.
notify2 :: Statement Notify ()
notify2 =
  Statement sql encoder Decoders.noResult True
  where
    sql :: ByteString
    sql =
      "SELECT pg_notify($1, $2)"

    encoder :: Encoders.Params Notify
    encoder =
      ((\Notify {channel} -> channel) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\Notify {payload} -> payload) >$< Encoders.param (Encoders.nonNullable Encoders.text))

--

libpq :: (LibPQ.Connection -> IO a) -> Session a
libpq action = do
  conn <- ask
  liftIO (Connection.withLibPQConnection conn action)

builderToByteString :: ByteString.Builder.Builder -> ByteString
builderToByteString =
  ByteString.Lazy.toStrict . ByteString.Builder.toLazyByteString
{-# INLINE builderToByteString #-}

-- Escape " as "", so e.g. `listen "foo\"bar"` will send the literal bytes: LISTEN "foo""bar"
escapeIdentifier :: Text -> ByteString.Builder.Builder
escapeIdentifier ident =
  Text.encodeUtf8BuilderEscaped escape ident
  where
    escape :: ByteString.Builder.Prim.BoundedPrim Word8
    escape =
      ByteString.Builder.Prim.condB
        (== 34) -- double-quote
        ( ByteString.Builder.Prim.liftFixedToBounded
            ( const ('"', '"')
                ByteString.Builder.Prim.>$< ByteString.Builder.Prim.char7
                  ByteString.Builder.Prim.>*< ByteString.Builder.Prim.char7
            )
        )
        (ByteString.Builder.Prim.liftFixedToBounded ByteString.Builder.Prim.word8)

-- Parse a Notify from a LibPQ.Notify
parseNotification :: LibPQ.Notify -> Notification
parseNotification notification =
  Notification
    { channel = Text.decodeUtf8 (LibPQ.notifyRelname notification),
      payload = Text.decodeUtf8 (LibPQ.notifyExtra notification),
      pid = LibPQ.notifyBePid notification
    }
