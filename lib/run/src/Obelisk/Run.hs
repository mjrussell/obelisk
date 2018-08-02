{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Obelisk.Run where

import Control.Concurrent
import Control.Exception
import Control.Lens ((^?), _Just, _Right)
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.List (uncons)
import Data.Maybe
import Data.Semigroup ((<>))
import Data.Streaming.Network (bindPortTCP)
import qualified Data.Text as T
import Language.Javascript.JSaddle.Run (syncPoint)
import Language.Javascript.JSaddle.Types (JSM)
import Language.Javascript.JSaddle.WebSockets
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import qualified Network.HTTP.ReverseProxy as RP
import qualified Network.HTTP.Types as H
import Network.Socket
import Network.Wai (Application, Middleware)
import qualified Network.Wai as W
import Network.Wai.Handler.Warp
import Network.Wai.Handler.Warp.Internal (settingsHost, settingsPort)
import Network.Wai.Handler.WebSockets (isWebSocketsReq)
import Network.WebSockets (ConnectionOptions)
import Network.WebSockets.Connection (defaultConnectionOptions)
import Obelisk.ExecutableConfig (get)
import Reflex.Dom.Core
import System.Environment
import System.IO
import System.Process
import Text.URI (URI)
import qualified Text.URI as URI
import Text.URI.Lens

run :: Int -- ^ Port to run the backend
    -> IO () -- ^ Backend
    -> (StaticWidget () (), Widget () ()) -- ^ Frontend widget (head, body)
    -> IO ()
run port backend frontend = do
  let handleBackendErr (e :: IOException) = hPutStrLn stderr $ "backend stopped; make a change to your code to reload - error " <> show e
  backendTid <- forkIO $ handle handleBackendErr $ withArgs ["--quiet", "--port", show port] backend
  putStrLn $ "Backend running on port " <> show port
  let conf = defRunConfig { _runConfig_redirectPort = port }
  runWidget conf frontend `finally` killThread backendTid

getConfigRoute :: IO (Maybe URI)
getConfigRoute = get "common/route" >>= \case
  Just r -> case URI.mkURI $ T.strip r of
    Just route -> pure $ Just route
    Nothing -> do
      putStrLn $ "Route is invalid: " <> show r
      pure Nothing
  Nothing -> pure Nothing

defAppUri :: URI
defAppUri = fromMaybe (error "defAppUri") $ URI.mkURI "http://127.0.0.1:8000"

runWidget :: RunConfig -> (StaticWidget () (), Widget () ()) -> IO ()
runWidget conf (h, b) = do
  uri <- fromMaybe defAppUri <$> getConfigRoute
  let port = fromIntegral $ fromMaybe 80 $ uri ^? uriAuthority . _Right . authPort . _Just
      -- FIXME: Pull out to the command line via RunConfig or other settings
      liveReload = True
      redirectHost = _runConfig_redirectHost conf
      redirectPort = _runConfig_redirectPort conf
      beforeMainLoop = do
        putStrLn $ "Frontend running on " <> T.unpack (URI.render uri)
      settings = setPort port (setTimeout 3600 defaultSettings)
  man <- newManager defaultManagerSettings
  backend <- fallbackProxy redirectHost redirectPort man
  if liveReload
    then debugWrapper $ \withRefresh registerContext -> do
      app <- obeliskApp defaultConnectionOptions h b backend withRefresh registerContext True
      runSettings settings app
    else do
      app <- obeliskApp defaultConnectionOptions h b backend id (pure ()) False
      runSettings settings app

-- TODO anyway we can get the original bracket/bindPortTCPRetry back in?
--  bracket
--    (bindPortTCPRetry settings (logPortBindErr port) (_runConfig_retryTimeout conf))
--    close
--    (\skt -> do
--        --app <- obeliskApp defaultConnectionOptions h b (fallbackProxy redirectHost redirectPort man)
--        --runSettingsSocket settings skt app)
--        debugWrapper $ \withRefresh registerContext -> do
--          app <- obeliskAppDebug defaultConnectionOptions h b (fallbackProxy redirectHost redirectPort man) withRefresh registerContext
--          runSettingsSocket settings skt app
--    )

obeliskApp :: ConnectionOptions -> StaticWidget () () -> Widget () () -> Application -> Middleware -> JSM () -> Bool -> IO Application
obeliskApp opts h b backend middleware preEntry shouldReload = do
  html <- BSLC.fromStrict <$> indexHtml h
  let entryPoint = preEntry >> mainWidget' b >> syncPoint
  jsaddle <- jsaddleOr opts entryPoint $ \req sendResponse -> case (W.requestMethod req, W.pathInfo req) of
    ("GET", []) -> sendResponse $ W.responseLBS H.status200 [("Content-Type", "text/html")] html
    ("GET", ["jsaddle.js"]) -> sendResponse $ W.responseLBS H.status200 [("Content-Type", "application/javascript")] $ jsaddleJs shouldReload
    _ -> backend req sendResponse
  -- Workaround jsaddleOr wanting to handle all websockets requests without
  -- having a chance for run to proxy non jsaddle websocket requests to the
  -- backend.
  return . middleware $ \req sendResponse -> do
    if isWebSocketsReq req && not (null $ W.pathInfo req)
      then backend req sendResponse
      else jsaddle req sendResponse

indexHtml :: StaticWidget () () -> IO ByteString
indexHtml h = do
  ((), bs) <- renderStatic $ el "html" $ do
    el "head" $ h
    el "body" $ return ()
    elAttr "script" ("src" =: "/jsaddle.js") $ return ()
  return $ "<!DOCTYPE html>" <> bs

-- | like 'bindPortTCP' but reconnects on exception
bindPortTCPRetry :: Settings
                 -> (IOError -> IO ()) -- ^ Action to run the first time an exception is caught
                 -> Int
                 -> IO Socket
bindPortTCPRetry settings m n = catch (bindPortTCP (settingsPort settings) (settingsHost settings)) $ \(e :: IOError) -> do
  m e
  threadDelay $ 1000000 * n
  bindPortTCPRetry settings (\_ -> pure ()) n

logPortBindErr :: Int -> IOError -> IO ()
logPortBindErr p e = getProcessIdForPort p >>= \case
  Nothing -> putStrLn $ "runWidget: " <> show e
  Just pid -> putStrLn $ unwords [ "Port", show p, "is being used by process ID", show pid <> ".", "Please kill that process or change the port in config/common/route."]

getProcessIdForPort :: Int -> IO (Maybe Int)
getProcessIdForPort port = do
  xs <- lines <$> readProcess "ss" ["-lptn", "sport = " <> show port] mempty
  case uncons xs of
    Just (_, x:_) -> return $ A.maybeResult $ A.parse parseSsPid $ BSC.pack x
    _ -> return Nothing

parseSsPid :: A.Parser Int
parseSsPid = do
  _ <- A.count 5 $ A.takeWhile (not . A.isSpace) *> A.skipSpace
  _ <- A.skipWhile (/= ':') >> A.string ":((" >> A.skipWhile (/= ',')
  A.string ",pid=" *> A.decimal

fallbackProxy :: ByteString -> Int -> Manager -> Application
fallbackProxy host port = RP.waiProxyTo handleRequest RP.defaultOnExc
  where handleRequest _req = return $ RP.WPRProxyDest $ RP.ProxyDest host port

data RunConfig = RunConfig
  { _runConfig_port :: Int
  , _runConfig_redirectHost :: ByteString
  , _runConfig_redirectPort :: Int
  , _runConfig_retryTimeout :: Int -- seconds
  }

defRunConfig :: RunConfig
defRunConfig = RunConfig
  { _runConfig_port = 8000
  , _runConfig_redirectHost = "127.0.0.1"
  , _runConfig_redirectPort = 3001
  , _runConfig_retryTimeout = 1
  }
