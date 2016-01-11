{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module DBus.Reactive where

import           Control.Concurrent
import           Control.Concurrent.STM
import qualified Control.Exception as Ex
import           Control.Monad.Trans
import           DBus
import           Data.Monoid
import           Data.Text (Text)
import           FRP.Sodium
import           System.Log.Logger

logError :: String -> IO ()
logError = errorM "DBus.Reactive"

logDebug :: String -> IO ()
logDebug = debugM "DBus.Reactive"


-- | Handle incoming signals as events
signalEvent :: Representable a =>
               SignalDescription (FlattenRepType (RepType a))
            -> Maybe Text
            -> DBusConnection
            -> IO (Event a)
signalEvent sigD mbRemote con = do
    (event, push) <- sync newEvent
    handleSignal sigD mbRemote mempty (sync . push) con
    return event

-- | Export a behaviour as a DBus property
behaviourToProperty :: Representable a =>
                       ObjectPath
                    -> Text
                    -> Text
                    -> Behaviour a
                    -> DBusConnection
                    -> IO (Property (RepType a))
behaviourToProperty path iface name (b :: Behaviour a) con = do
    let get = Just . liftIO . sync $ sample b
        set = Nothing
        prop = mkProperty path iface name get set PECSTrue :: Property (RepType a)
        sendSig v = emitPropertyChanged prop v con
    _ <- sync $ listen (updates b) sendSig
    return prop

-- | Track a remote property as a behaviour
--
-- @throws: MsgError
propertyBehaviour' :: Representable a =>
                     Maybe a
                   ->  RemoteProperty (RepType a)
                   -> DBusConnection
                   -> IO (Behaviour a)
propertyBehaviour' def rprop con = do
    mbInit <- getProperty rprop con
    i <- case mbInit of
        Left e -> case def of
                   Nothing -> Ex.throwIO e
                   Just v -> do
                       logError $ "Error getting initial value" ++ show e
                       return v
        Right r -> return r
    (changeEvent, push) <- sync $ newEvent
    handlePropertyChanged rprop (handleP push) con
    sync $ hold i changeEvent
  where
    handleP push Nothing = do
        mbP <- getProperty rprop con
        case mbP of
         Left _e -> logError "could not get remote property"
         Right v -> sync $ push v
    handleP push (Just v ) = do
        logDebug $ "property changed: " ++ show rprop
        sync $ push v

propertyBehaviour :: Representable a =>
                     RemoteProperty (RepType a)
                  -> DBusConnection
                  -> IO (Behaviour a)
propertyBehaviour = propertyBehaviour' Nothing

eventMethod :: ( Representable args
               , Representable res) =>
               MethodDescription (FlattenRepType (RepType args))
                                 (FlattenRepType (RepType res))
            -> Text
            -> Event args
            -> DBusConnection
            -> Reactive (Event (Either MethodError res))
eventMethod methodDescription peer ev con = do
    (ev' , push) <- newEvent
    _ <- listen ev (\x -> do
                           res <- callAsync methodDescription peer x [] con
                           _ <-forkIO $ do
                               r <- atomically res
                               sync $ push r
                           return ()
                     )
    return ev'
