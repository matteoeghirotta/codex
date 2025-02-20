module Codex (Codex(..), defaultStackOpts, defaultTagsFileName, Verbosity, module Codex) where

import Network.HTTP.Client (httpLbs, Manager, Response(..), parseRequest)
import Control.Exception (try, SomeException, evaluate)
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Except
import Data.List ((\\))
import Conduit
import Data.Maybe
import Distribution.Package
import Distribution.Text
import Distribution.Verbosity
import Network.HTTP.Client (HttpException)
import System.Console.AsciiProgress (def, newProgressBar, Options(..), tick)
import System.Directory
import System.FilePath
import System.Process
import System.IO( IOMode( ReadMode ), withFile, hGetContents' )

import qualified Data.ByteArray.Encoding as BA
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip
import qualified Crypto.Hash as Crypto
import qualified Data.ByteString.Lazy as BS
import qualified Data.List as List
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as TextL
import qualified Data.Text.Lazy.IO as TLIO

import Codex.Internal
import Codex.Project

-- TODO Replace the `Codex` context with a `Control.Reader.Monad `.

-- TODO Remove that function once using `Text` widely
replace :: String -> String -> String -> String
replace a b c = Text.unpack $ Text.replace (Text.pack a) (Text.pack b) (Text.pack c)

md5hash :: String -> String
md5hash = Text.unpack . Text.decodeUtf8 . md5 . Text.encodeUtf8 . Text.pack
  where
    md5 = BA.convertToBase BA.Base16 . Crypto.hashWith Crypto.MD5

data Tagging = Tagged | Untagged
  deriving (Eq, Show)

fromBool :: Bool -> Tagging
fromBool True = Tagged
fromBool False = Untagged

data Status = Source Tagging | Archive | Remote
  deriving (Eq, Show)

type Action = ExceptT String IO

data Tagger = Ctags | Hasktags | HasktagsEmacs | HasktagsExtended
  deriving (Eq, Show, Read)

taggerCmd :: Tagger -> String
taggerCmd Ctags = "ctags --tag-relative=no --recurse -f \"$TAGS\" \"$SOURCES\""
taggerCmd Hasktags = "hasktags --ctags --follow-symlinks --output=\"$TAGS\" \"$SOURCES\""
taggerCmd HasktagsEmacs = "hasktags --etags --follow-symlinks --output=\"$TAGS\" \"$SOURCES\""
taggerCmd HasktagsExtended = "hasktags --ctags --follow-symlinks --extendedctag --output=\"$TAGS\" \"$SOURCES\""

taggerCmdRun :: Codex -> FilePath -> FilePath -> Action FilePath
taggerCmdRun cx sources tags' = do
  _ <- tryIO $ system command
  return tags' where
    command = replace "$SOURCES" sources $ replace "$TAGS" tags' $ tagsCmd cx

-- TODO It would be much better to work out which `Exception`s are thrown by which operations,
--      and store all of that in a ADT. For now, I'll just be lazy.
tryIO :: IO a -> Action a
tryIO io = do
  res <- liftIO $ (try :: IO a -> IO (Either SomeException a)) io
  either (throwE . show) return res

codexHash :: Codex -> String
codexHash cfg = md5hash $ show cfg

dependenciesHash :: [PackageIdentifier] -> String
dependenciesHash xs = md5hash $ xs >>= display

tagsFileHash :: Codex -> [PackageIdentifier] -> String -> String
tagsFileHash cx ds projectHash = md5hash $ concat [codexHash cx, dependenciesHash ds, projectHash]

computeCurrentProjectHash :: Codex -> IO String
computeCurrentProjectHash cx = if not $ currentProjectIncluded cx then return "*" else do
  -- xs <- runT $ (autoM getModificationTime) <~ (filtered p) <~ files <~ directoryWalk <~ source ["."]
  xs <- runConduitRes
      $  sourceDirectoryDeep True "."
      .| filterC p
      .| mapMC (lift . getModificationTime)
      .| sinkList
  return . md5hash . show $ maximum xs
    where
      p fp = any (\f -> f fp) (fmap List.isSuffixOf extensions)
      extensions = [".hs", ".lhs", ".hsc"]

isUpdateRequired :: Codex -> [PackageIdentifier] -> String -> Action Bool
isUpdateRequired cx ds ph = do
  fileExist <- tryIO $ doesFileExist file
  if fileExist then do
    content <- tryIO $ TLIO.readFile file
    let hash = TextL.toStrict . TextL.drop 17 . head . drop 2 $ TextL.lines content
    return $ hash /= Text.pack (tagsFileHash cx ds ph)
  else
    return True
  where
    file = tagsFileName cx

status :: FilePath -> PackageIdentifier -> Action Status
status root i = do
  sourcesExist <- tryIO . doesDirectoryExist $ packageSources root i
  archiveExist <- tryIO . doesFileExist $ packageArchive root i
  case (sourcesExist, archiveExist) of
    (True, _) -> fmap (Source . fromBool) (liftIO . doesFileExist $ packageTags root i)
    (_, True) -> return Archive
    (_, _)    -> return Remote

fetch :: Manager -> FilePath -> PackageIdentifier -> Action FilePath
fetch s root i = do
  bs <- tryIO $ do
    createDirectoryIfMissing True (packagePath root i)
    openLazyURI s url
  either throwE write bs where
      write bs = fmap (const archivePath) $ tryIO $ BS.writeFile archivePath bs
      archivePath = packageArchive root i
      url = packageUrl i

openLazyURI :: Manager -> String -> IO (Either String BS.ByteString)
openLazyURI manager url = do
  request <- parseRequest url
  eresp <- try $ httpLbs request manager
  pure $ case eresp of
    Left err ->
      Left $ showHttpEx err
    Right resp ->
      Right $ responseBody resp
  where
    showHttpEx :: HttpException -> String
    showHttpEx = show

extract :: FilePath -> PackageIdentifier -> Action FilePath
extract root i = fmap (const path) . tryIO $ read' path (packageArchive root i) where
  read' dir tar = Tar.unpack dir . Tar.read . GZip.decompress =<< BS.readFile tar
  path = packagePath root i

tags :: Builder -> Codex -> PackageIdentifier -> Action FilePath
tags bldr cx i = taggerCmdRun cx sources tags' where
    sources = packageSources hp i
    tags' = packageTags hp i
    hp = hackagePathOf bldr cx

doit :: FilePath -> IO () -> IO TextL.Text
-- doit f tick' = TLIO.readFile f <* tick'
doit f tick' = withFile f ReadMode (\h -> fmap TextL.pack (hGetContents' h) <* tick')

assembly :: Builder -> Codex -> [PackageIdentifier] -> String -> [WorkspaceProject] -> FilePath -> Action FilePath
assembly bldr cx dependencies projectHash workspaceProjects o = do
  xs <- join . maybeToList <$> projects workspaceProjects
  tryIO $ mergeTags (fmap tags' dependencies ++ xs) o
  return o where
    projects [] = return Nothing
    projects xs = do
      tick' <- newProgressBar' "Running tagger" (length xs)
      tmp <- liftIO getTemporaryDirectory
      ys <- traverse (\wsp -> tags'' tmp wsp <* tick') xs
      return $ Just ys where
        tags'' tmp (WorkspaceProject id' sources) = taggerCmdRun cx sources tags''' where
          tags''' = tmp </> concat [display id', ".tags"]
    mergeTags files' o' = do
      files'' <- filterM doesFileExist files'
      tick' <- newProgressBar' "Merging tags" (length files'')
      contents <- traverse (`doit` tick') files''
      case files' \\ files'' of
        [] -> return ()
        xs -> do
          putStrLn "codex: *warning* the following tags files where missings during assembly:"
          mapM_ putStrLn xs
          return ()
      let xs = concat $ fmap TextL.lines contents
          ys = if sorted then (Set.toList . Set.fromList) xs else xs
      TLIO.writeFile o' $ TextL.unlines (concat [headers, ys])
    tags' = packageTags $ hackagePathOf bldr cx
    headers = if tagsFileHeader cx then fmap TextL.pack [headerFormat, headerSorted, headerHash] else []
    headerFormat = "!_TAG_FILE_FORMAT\t2"
    headerSorted = concat ["!_TAG_FILE_SORTED\t", if sorted then "1" else "0"]
    headerHash = concat ["!_TAG_FILE_CODEX\t", tagsFileHash cx dependencies projectHash]
    sorted = tagsFileSorted cx


newProgressBar' :: (MonadIO m, MonadIO m2, Integral estimate) => String -> estimate -> m (m2 ())
newProgressBar' label est = liftIO $ do
  bar <- newProgressBar options
  return (liftIO (tick bar))
  where
    options =  def {
       pgTotal = fromIntegral est
     , pgFormat = label ++ " :percent [:bar] :current/:total (for :elapsed, :eta remaining)"
     }
