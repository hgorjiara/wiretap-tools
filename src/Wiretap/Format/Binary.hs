module Wiretap.Format.Binary (readEvents, readHistoryEvents) where

import System.IO
import           System.FilePath
import Debug.Trace

import GHC.Int (Int64)

import qualified Data.ByteString.Lazy as BL

import Data.Binary.Get
import Data.Word
import Data.Bits

import Wiretap.Data.Event
import Wiretap.Data.Program

import Pipes
import Pipes.ByteString
import Pipes.Binary

readLog' :: FilePath -> IO ()
readLog' fp =
  withFile fp ReadMode $ \handle ->
    runEffect $ readLog (parseThread fp) handle >-> printAll

  where
    parseThread =
      Thread . read . takeBaseName

printAll :: Consumer Event IO ()
printAll = do
  event <- await
  lift $ print event
  printAll

readLog :: Thread -> Handle -> Producer Event IO ()
readLog t handle =
  fromHandle handle >-> logEvents t

logEvents :: Monad m => Thread -> Pipe ByteString Event m ()
logEvents t =
  yield $ Event t 0 nullInst Begin
  logEvents' t 1

logEvents' :: Monad m => Thread -> Int -> Pipe ByteString Event m ()
logEvents' t i = do
  byte <- drawByte
  case byte of
    Just w -> return ()
    Nothing ->
      yield $ Event t i nullInst End

readEvents :: Thread -> Handle -> IO [Event]
readEvents t handle = do
  bytes <- BL.hGetContents handle
  return $ (Event t 0 nullInst Begin): getEvents t 1 bytes

readHistoryEvents :: Handle -> IO [Event]
readHistoryEvents handle = do
  bytes <- BL.hGetContents handle
  return $ getHistoryEvents bytes

getEvents :: Thread -> Int -> BL.ByteString -> [Event]
getEvents t i bytes =
  case readEvent t i bytes of
    Just (event, rest) -> event : getEvents t (i + 1) rest
    Nothing -> [Event t i nullInst End]

readEvent :: Thread -> Int -> BL.ByteString -> Maybe (Event, BL.ByteString)
readEvent t i bytes =
  case BL.uncons bytes of
    Just (w, rest) ->
      let (inst, rest') = readInstruction rest
          (opr, rest'') = readOperation w rest'
      in Just (Event t i inst opr, rest'')
    Nothing -> Nothing
{-# INLINE readEvent #-}

getHistoryEvents :: BL.ByteString -> [Event]
getHistoryEvents bytes =
  if BL.null bytes
  then []
  else
    let (event, rest) = readHistoryEvent bytes in
    event : getHistoryEvents rest

readHistoryEvent :: BL.ByteString -> (Event, BL.ByteString)
readHistoryEvent bytes =
  let (t, bytes')  = readGet 4 getThread bytes in
  let (i, bytes'') = readGet 4 (fromIntegral <$> getWord32be) bytes' in
  case BL.uncons bytes'' of
    Just (w, rest) ->
      let (inst, rest') = readInstruction rest
          (opr, rest'') = readOperation w rest'
      in (Event t i inst opr, rest'')
    Nothing -> error "Unexpected end of file"
{-# INLINE readHistoryEvent #-}

readInstruction :: BL.ByteString -> (Instruction, BL.ByteString)
readInstruction =
  readGet 4 $ Instruction <$> fromIntegral <$> getWord32be
{-# INLINE readInstruction #-}

readOperation :: Word8 -> BL.ByteString -> (Operation, BL.ByteString)
readOperation w =
  case w .&. 0x0f of
    0 -> readN 4 $ Synch . runGet (fromIntegral <$> getWord32be)
    1 -> readN 4 $ Fork . runGet getThread
    2 -> readN 4 $ Join . runGet getThread
    3 -> readN 4 $ Request . runGet getRef
    4 -> readN 4 $ Acquire . runGet getRef
    5 -> readN 4 $ Release . runGet getRef
    6 -> -- Read
      readN (valueSize w + 8) $ \bytes ->
        let (locs, rest) = BL.splitAt 8 bytes in
        Read (runGet getLocation locs) (runGet (getValue w) rest)

    7 -> -- Write
      readN (valueSize w + 8) $ \bytes ->
        let (locs, rest) = BL.splitAt 8 bytes in
        Write (runGet getLocation locs) (runGet (getValue w) rest)

    a ->
      error $ "Problem in readOperation: "
               ++ show a ++ " from: "
               ++ show w

  where
    getRef =
      Ref <$> getWord32be

    getField =
      Field . fromIntegral <$> getWord32be

    getLocation = do
      object <- getRef
      if pointer object == 0
        then Static <$> getField
        else Array object . fromIntegral <$> getWord32be

    getValue :: Word8 -> Get Value
    getValue operation =
      case (operation .&. 0xf0) `shiftR` 4 of
        0 -> -- Byte
          Byte <$> getWord8
        1 -> -- Char
          Char <$> getWord8
        2 -> -- Short
          Short <$> getWord16be
        3 -> -- Int
          Integer <$> getWord32be
        4 -> -- Long
          Long <$> getWord64be
        5 -> -- Float
          Float <$> getWord32be
        6 -> -- Double
          Double <$> getWord64be
        7 -> -- Object
          Object <$> getWord32be
        a ->
          error $ "Problem in getValue: " ++ show a
{-# INLINE readOperation #-}

getThread :: Get Thread
getThread =
  Thread . fromIntegral <$> getWord32be
{-# INLINE getThread #-}

onfst :: (a -> b) -> (a, c) -> (b, c)
onfst f (a, b) =
  (f a, b)
{-# INLINE onfst #-}

readN :: Int64 -> (BL.ByteString -> a) -> BL.ByteString -> (a, BL.ByteString)
readN i f =
  onfst f . BL.splitAt i
{-# INLINE readN #-}

readGet :: Int64 -> (Get a) -> BL.ByteString -> (a, BL.ByteString)
readGet i =
  readN i . runGet
{-# INLINE readGet #-}

valueSize :: Word8 -> Int64
valueSize w =
  case (w .&. 0xf0) `shiftR` 4 of
    0 -> 1
    1 -> 1
    2 -> 2
    3 -> 4
    4 -> 8
    5 -> 4
    6 -> 8
    7 -> 4
    a -> error $ "Bad event value " ++ show a
{-# INLINE valueSize #-}
