{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module DBus.Reactive
  ( Network (..)
  , newNet
  , listen
  , listen'
  , sync
  , signalEvent
  , behaviourToProperty
  , propertyBehaviour'
  , propertyBehaviour
  , eventMethod
  , eventSignal
  ) where

import           Control.Concurrent
import           Control.Concurrent.STM
import qualified Control.Exception as Ex
import           Control.Monad.Trans
import           DBus
import           DBus.Signal
import           Data.IORef
import           Data.Text (Text)
import           Reactive.Banana
import           Reactive.Banana.Frameworks
import           System.Log.Logger

logError :: String -> IO ()
logError = errorM "DBus.Reactive"

logDebug :: String -> IO ()
logDebug = debugM "DBus.Reactive"

newtype Network = Network { run :: MomentIO () -> IO () }

newNet :: IO Network
newNet = do
    (ah, call) <- newAddHandler
    network <- compile (do
        globalExecuteEV <- fromAddHandler ah
        _ <- execute globalExecuteEV
        return () )
    actuate network
    return $ Network { run = call
                     }


listen :: Event a -> (a -> IO ()) -> MomentIO ()
listen ev f = do
    reactimate (f <$> ev)

listen' :: Event (Future a) -> (a -> IO ()) -> MomentIO ()
listen' ev f = do
    reactimate' (fmap f <$> ev)

sync :: Network -> MomentIO a -> IO a
sync Network{run = run} f = do
    ref <- newIORef (error "Network hasn't written result to ref")
    run $ do
        res <- f
        liftIO $ writeIORef ref res
    readIORef ref

-- | Handle incoming signals as events
signalEvent :: Representable a =>
               SignalDescription (FlattenRepType (RepType a))
            -> Maybe Text
            -> Network
            -> DBusConnection
            -> IO (Event a)
signalEvent sigD mbRemote network con = do
    (event, push) <- sync network $ newEvent
    handleSignal sigD mbRemote mempty push con
    return event

-- | Export a behaviour as a DBus property
behaviourToProperty :: Representable a =>
                       ObjectPath
                    -> Text
                    -> Text
                    -> Network
                    -> Behavior a
                    -> DBusConnection
                    -> IO (Property (RepType a))
behaviourToProperty path iface name net (b :: Behavior a) con = do
    let get = Just . liftIO . sync net $ valueB b
        set = Nothing
        prop = mkProperty path iface name get set PECSTrue :: Property (RepType a)
        sendSig v = emitPropertyChanged prop v con
    _ <- sync net $ do
        chs <- changes b
        listen' chs sendSig
    return prop

-- | Track a remote property as a behaviour
--
-- @throws: MsgError
propertyBehaviour' :: Representable a =>
                      Maybe a
                   -> RemoteProperty (RepType a)
                   -> Network
                   -> DBusConnection
                   -> IO (Behavior a)
propertyBehaviour' def rprop net con = do
    mbInit <- getProperty rprop con
    i <- case mbInit of
        Left e -> case def of
                   Nothing -> Ex.throwIO e
                   Just v -> do
                       logError $ "Error getting initial value" ++ show e
                       return v
        Right r -> return r
    (bhv, push) <- sync net $ newBehavior i
    handlePropertyChanged rprop (handleP push) con
    return bhv
  where
    handleP push Nothing = do
        mbP <- getProperty rprop con
        case mbP of
         Left _e -> logError "could not get remote property"
         Right v -> push v
    handleP push (Just v ) = do
        logDebug $ "property changed: " ++ show rprop
        push v

-- | Track a remote property as a behaviour, throws an exception if the initial
-- pull doesn't succeed
propertyBehaviour :: Representable a =>
                     RemoteProperty (RepType a)
                  -> Network
                  -> DBusConnection
                  -> IO (Behavior a)
propertyBehaviour = propertyBehaviour' Nothing

-- | Call a method when an event fires
eventMethod :: ( Representable args
               , Representable res) =>
               MethodDescription (FlattenRepType (RepType args))
                                 (FlattenRepType (RepType res))
            -> Text
            -> Event args
            -> Network
            -> DBusConnection
            -> IO (Event (Either MethodError res))
eventMethod methodDescription peer ev net con = sync net $ do
    (ev' , push) <- newEvent
    _ <- listen ev (\x -> do
                           res <- callAsync methodDescription peer x [] con
                           _ <- forkIO $ do
                                r <- atomically res
                                push r
                           return ()
                     )
    return ev'

eventSignal  :: Representable a =>
                Event a
             -> SignalDescription (FlattenRepType (RepType a))
             -> DBusConnection
             -> MomentIO ()
eventSignal event signal con = do
    listen event $ \v -> emitSignal signal v con
