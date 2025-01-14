{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import           System.Console.Docopt
import           System.Directory
import           System.Environment               (getArgs)
import           System.FilePath
import           System.IO

import           Control.Applicative
import           Control.Lens                     (over, _2)
import           Control.Monad
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.State.Strict

import           Data.Unique

import qualified Data.List                        as L
import qualified Data.Map                         as M
import           Data.Maybe                       (fromMaybe, catMaybes)
import qualified Data.Set                         as S

import           Pipes
import qualified Pipes.Prelude                    as P
import qualified Pipes.Missing                    as PM
import qualified Pipes.Lift                       as PL

import           Wiretap.Analysis.Count
import           Wiretap.Format.Binary
import           Wiretap.Format.Text
import           Wiretap.Utils

import           Wiretap.Data.Event
import           Wiretap.Data.History
import qualified Wiretap.Data.Program             as Program

import           Wiretap.Analysis.DataRace
import           Wiretap.Analysis.LIA             hiding ((~>))
import           Wiretap.Analysis.Lock
import           Wiretap.Analysis.Permute

patterns :: Docopt
patterns = [docopt|wiretap-tools version 0.1.0.0

Usage:
   wiretap-tools (count|size) [<history>]
   wiretap-tools parse [-Ph] [<history>]
   wiretap-tools lockset [-vh] [<history>]
   wiretap-tools dataraces [options] [<history>]
   wiretap-tools deadlocks [options] [<history>]
   wiretap-tools (--help | --version)

Options:
-h, --human-readable           Adds more information about execution

-P PROGRAM, --program PROGRAM  The path to the program information, the default
                               is the folder of the history if none is declared.

-f FILTER, --filter FILTER     For use in a candidate analysis. The multible filters
                               can be added seperated by commas. See filters.

-p PROVER, --prover PROVER     For use in a candidate analysis, if no prover is
                               provided, un verified candidates are produced.

-o OUT, --proof OUT            Produces the proof in the following directory

--chunk-size CHUNK_SIZE        For use to set a the size of the chunks, if not
                               set the program will read the entier history.

--chunk-offset CHUNK_OFFSET    Chunk offset is the number of elements dropped each
                               after each chunk. The minimal offset is 1, and the
                               maximal offset, which touches all events is the
                               size.

-v, --verbose                  Produce verbose outputs

Filters:
Filters are applicable to dataraces and deadlock analyses.

  lockset:   Remove all candidates with shared locks.
  reject:    Rejects all candidates
  uniqe:     Only try to prove each candidate once

Provers:
A prover is an algorithm turns a history into a constraint.

  said:      The prover used in [Said 2011].
  free:      A prover that only uses must-happen-before constraints, and sequential
             consistency.
  none:      No constraints except that the candidate has to be placed next to
             each other.
  kalhauge:  The data flow sentisive control-flow consistency alogrithm [default].
|]

data Config = Config
  { verbose       :: Bool
  , prover        :: String
  , filters       :: [String]
  , outputProof   :: Maybe FilePath
  , program       :: Maybe FilePath
  , history       :: Maybe FilePath
  , humanReadable :: Bool
  , chunkSize    :: Maybe Int
  , chunkOffset  :: Int
  } deriving (Show, Read)

getArgOrExit :: Arguments -> Option -> IO String
getArgOrExit = getArgOrExitWith patterns

helpNeeded :: Arguments -> Bool
helpNeeded args =
  args `isPresent` longOption "help"

main :: IO ()
main = do
  parseArgs patterns <$> getArgs >>= \case
    Right args -> do
      when (helpNeeded args) $ exitWithUsage patterns
      config <- readConfig args
      runCommand args config
    Left err ->
      exitWithUsageMessage patterns (show err)

readConfig :: Arguments -> IO Config
readConfig args = do
  return $ Config
    { verbose = isPresent args $ longOption "verbose"
    , filters = splitOn ','
        $ getArgWithDefault args "unique,lockset" (longOption "filter")
    , prover = getArgWithDefault args "kalhauge" (longOption "prover")
    , outputProof = getLongOption "proof"
    , program = getLongOption "program"
    , history = getArgument "history"
    , chunkSize = read <$> getLongOption "chunk-size"
    , chunkOffset = fromMaybe 1 (read <$> getLongOption "chunk-offset")
    , humanReadable = args `isPresent` longOption "human-readable"
    }
  where
    getLongOption = getArg args . longOption
    getArgument = getArg args . argument

runCommand :: Arguments -> Config -> IO ()
runCommand args config = do
  p <- getProgram config

  let
    pprint :: Show (PP a) => a -> String
    pprint = pp p

  onCommand "parse" $ \events -> do
    runEffect $ for events $ \e -> do
      i <- lift (instruction p e)
      lift $ do
        putStrLn $ pprint e
        putStr "        "
        putStrLn $ Program.instName p i

  onCommand "count" $
    countEvents >=> print

  onCommand "size" $
    P.length >=> print

  onCommand "lockset" $ \events -> do
    locks <- lockset . fromEvents <$> P.toListM events
    forM_ locks $ printLockset pprint . over _2 (L.intercalate "," . map pprint . M.assocs)

  onCommand "dataraces" $
    proveCandidates config
      (each . raceCandidates) $ dataRaceToString p

  onCommand "deadlocks" $
    proveCandidates config (
      \s -> do
        lm <- lift $ gets lockMap
        each $ deadlockCandidates' s lm
      ) $ deadlockToString p

  where
    getProgram cfg =
      maybe (return Program.empty) Program.fromFolder $
        program config <|> fmap takeDirectory (history cfg)

    deadlockToString :: Program.Program -> Deadlock -> IO String
    deadlockToString p (Deadlock (DeadlockEdge _ aA aR) (DeadlockEdge _ bA bR)) = do
       as <- sequence . map (instruction p . normal) $ [aA, aR]
       bs <- sequence . map (instruction p . normal) $ [bA, bR]
       return . L.intercalate ";" . L.sort .
         L.map (L.intercalate "," . L.sort . L.map (pp p)) $ [as, bs]

    dataRaceToString p (DataRace l a b) | humanReadable config =
      return $ padStr a' ' ' 60 ++ padStr b' ' ' 60 ++ pp p l
      where [a', b'] = map (pp p) [a, b]

    dataRaceToString p (DataRace _ a b) = do
      datarace <- mapM (instruction p . normal) [a, b]
      return $ unwords . L.sort $ map (pp p) datarace

    printLockset pprint (e, locks) | humanReadable config =
      putStrLn $ padStr (pprint e) ' ' 60 ++ " - " ++ locks
    printLockset _ (_, locks) =
      putStrLn locks

    withHistory :: (Handle -> IO ()) -> IO ()
    withHistory f =
      case history config of
        Just events -> do
          withFile events ReadMode f
        Nothing -> do
          f stdin

    onCommand :: String -> (Producer Event IO () -> IO ()) -> IO ()
    onCommand cmd f =
      when (args `isPresent` command cmd) $
        withHistory (f . readHistory)

    padStr p char size =
      p ++ L.replicate (size - length p) char

type LockState = M.Map Thread [(Ref, UE)]

data ProverState = ProverState
  { proven :: S.Set String
  , lockMap :: UniqueMap (M.Map Ref UE)
  , lockState :: LockState
  } deriving (Show)

addProven :: String -> ProverState -> ProverState
addProven a p =
   p { proven = S.insert a $ proven p }

updateLockState :: (LockState -> LockState) -> ProverState -> ProverState
updateLockState f p =
   p { lockState = f (lockState p) }

setLockMap :: PartialHistory h => h -> ProverState -> ProverState
setLockMap h p =
  p { lockMap = fst $ locksetSimulation (lockState p) h }

type ProverT m = StateT ProverState m


proveCandidates
  :: forall a m. (Candidate a, Show a, Ord a, MonadIO m)
  => Config
  -> (forall h . (PartialHistory h) => h -> Producer a (ProverT m) ())
  -> (a -> IO String)
  -> Producer Event m ()
  -> m ()
proveCandidates config generator toString events =
  runEffect $ uniqueEvents >-> PL.evalStateP initialState proverPipe

  where
    initialState =
      (ProverState S.empty (fromUniques []) M.empty)

    logV :: (MonadIO m') => String -> m' ()
    logV = liftIO . when (verbose config) . hPutStrLn stderr

    uniqueEvents =
       PM.finite' (events >-> PM.scan' (\i e -> (i+1, Unique i e)) 0)

    proverPipe =
      chunkate >-> forever (await >>= lift . chunkProver)

    chunkate :: Pipe (Maybe UE) [UE] (ProverT m) ()
    chunkate =
      case chunkSize config of
        Nothing -> do
          -- Read the entire history
          list <- PM.asList $ PM.recoverAll >-> PM.end'
          yield list
        Just size ->
          -- Read a little at a time
          getN size >>= go size
      where
        offset = chunkOffset config

        go size chunk = do
          lift . modify $ setLockMap chunk
          -- lm <- lift $ gets lockMap
          ls <- lift $ gets lockState
          yield chunk
          case chunk of
              a:_ -> logV $
                "At event " ++ show (idx a)
                 -- ++ " " ++ show (L.length chunk)
                 ++ " " ++ show (M.size ls)
                -- ++ " " ++ show (IM.size . toIntMap $ lm)
              [] -> return ()
          if actualChunkSize < size
            then logV $ "Done"
            else do
              new <- getN offset
              let (dropped, remainder) = splitAt offset chunk
              lift . modify $ updateLockState (\s -> snd $ locksetSimulation s dropped)
              go size $ remainder ++ new
          where actualChunkSize = length chunk

        getN size = do
          catMaybes <$> PM.asList (PM.take' size)

    chunkProver
      :: forall h. (PartialHistory h)
      => h
      -> StateT ProverState m ()
    chunkProver chunk =
      runEffect . for (generator chunk) $ \c ->  do
        -- lift get >>= liftIO . print
        lift $ candidateProver chunk c
        -- lift get >>= liftIO . print

    candidateProver hist c = do
      result <- runEitherT $
        runAll c (map getFilter $ filters config)
        >>= permute (getProver $ prover config) hist
      case result of
        Left msg -> liftIO $ do
          when (verbose config) $ do
            hPutStrLn stderr "Could not prove candidate:"
            hPutStr stderr "  " >> toString c >>= hPutStrLn stderr
            hPutStrLn stderr "The reason was:"
            hPutStr stderr "  " >> hPutStrLn stderr msg
        Right proof -> do
          str <- liftIO . toString $ candidate proof
          modify $ addProven str
          liftIO $ printProof proof

    printProof (Proof c _ hist) = do
      putStrLn =<< toString c
      case outputProof config of
        Just folder -> do
          createDirectoryIfMissing True folder
          let (Unique ia _, Unique ib _) = toEventPair c
          withFile (folder </> show ia ++ "-" ++ show ib ++ ".hist") WriteMode $
            \h -> runEffect $ each hist >-> P.map normal >-> writeHistory h
        Nothing ->
          return ()

    getFilter name =
      case name of
        "lockset" -> \c -> do
          lm <- lift $ gets lockMap
          locksetFilter' lm c
        "reject" ->
          const $ left "Rejected"
        "unique" -> \c -> do
          str <- liftIO $ toString c
          alreadyProven <- lift $ gets (S.member str . proven)
          if alreadyProven
            then left "Already proven"
            else return c
        _ ->
          error $ "Unknown filter " ++ name

    getProver name =
      case name of
        "said"     -> said
        "kalhauge" -> kalhauge
        "free"     -> free
        "none"     -> none
        _          -> error $ "Unknown prover: '" ++ name ++ "'"

runAll :: (Monad m') => a -> [a -> m' a] -> m' a
runAll a = L.foldl' (>>=) $ pure a

cnf2dot
  :: PartialHistory h
  => Program.Program
  -> h
  -> [[LIAAtom (Unique Event)]]
  -> String
cnf2dot p h cnf = unlines $
  [ "digraph {"
  , "graph [overlap=false, splines=true];"
  , "edge [ colorscheme = dark28 ]"
  ]
  ++ [ unlines $ zipWith printEvent [0..] (Wiretap.Data.History.enumerate h)]
  ++ [ unlines $ printConjunction color cj
     | (color, cj) <- zip (cycle $ map show ([1..8] :: [Int])) cnf
     ]
  ++ [ "}" ]
  where
    pprint = pp p
    pr u = "O" ++ show (idx u)

    printEvent :: Int -> UE -> String
    printEvent i u@(Unique _ event) =
      pr u ++ " [ shape = box, fontsize = 10, label = \""
           ++ pprint (operation event) ++ "\", "
           ++ "pos = \"" ++ show (threadId (thread event) * 200)
           ++ "," ++ show (- i * 75) ++ "!\" ];"

    events = S.fromList (Wiretap.Data.History.enumerate h)
    printAtom color constrain atom =
      case atom of
        AOrder a b | a `S.member` events &&  b `S.member` events ->
           "\"" ++ pr a ++ "\" -> \"" ++ pr b ++ "\" "
           ++ if constrain
              then ";"
              else "[ style=dashed, color=\"" ++ color ++ "\"];"
        AEq a b ->
             "\"" ++ pr a ++ "\" -> \"" ++ pr b ++ "\"; "
          ++ "\"" ++ pr b ++ "\" -> \"" ++ pr a ++ "\""
        _ -> ""

    printConjunction _ [e] =
      [ printAtom "black" True e ]
    printConjunction color es =
      map (printAtom color False) es
