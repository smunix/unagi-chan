{-# LANGUAGE BangPatterns , DeriveDataTypeable, CPP #-}
module Control.Concurrent.Chan.Unagi.NoBlocking.Internal
#ifdef NOT_x86
    {-# WARNING "This library is unlikely to perform well on architectures without a fetch-and-add instruction" #-}
#endif
    (sEGMENT_LENGTH
    , InChan(..), OutChan(..), ChanEnd(..), StreamSegment, Cell, Stream(..)
    , NextSegment(..), StreamHead(..)
    , newChanStarting, writeChan, readChan, readChanYield, Element(..)
    , dupChan
    , isActive
    )
    where

-- Forked from src/Control/Concurrent/Chan/Unagi/Internal.hs at 065cd68010
--
-- Some detailed NOTEs present in Control.Concurrent.Chan.Unagi have been
-- removed here although they still pertain. If you intend to work on this 
-- module, please be sure you're familiar with those concerns.
--
-- The implementation here is Control.Concurrent.Chan.Unagi with the blocking
-- read mechanics removed, the required CAS rendevouz replaced with
-- writeArray/readArray, and MPSC/SPMC/SPSC variants that eliminate streamHead
-- updates and atomic operations on any 'S' sides.

import Data.IORef
import Control.Exception
import Control.Monad.Primitive(RealWorld)
import Data.Atomics.Counter.Fat
import Data.Atomics
import qualified Data.Primitive as P
import Control.Monad
import Control.Applicative
import Data.Bits
import Data.Typeable(Typeable)
import Control.Concurrent(yield)

import Control.Concurrent.Chan.Unagi.Constants


-- | The write end of a channel created with 'newChan'.
data InChan a = InChan !(IORef Bool) -- Used for creating an OutChan in dupChan
                       !(ChanEnd a)
    deriving (Typeable,Eq)

-- | The read end of a channel created with 'newChan'.
data OutChan a = OutChan !(IORef Bool) -- Is corresponding InChan still alive?
                         !(ChanEnd a) 
    deriving (Typeable,Eq)

instance Eq (ChanEnd a) where
     (ChanEnd _ _ headA) == (ChanEnd _ _ headB)
        = headA == headB

-- TODO POTENTIAL CPP FLAGS (or functions)
--   - Strict element (or lazy? maybe also expose a writeChan' when relevant?)
--   - sEGMENT_LENGTH
--   - reads that clear the element immediately (or export as a special function?)

-- InChan & OutChan are mostly identical, sharing a stream, but with
-- independent counters
data ChanEnd a = 
           -- an efficient producer of segments of length sEGMENT_LENGTH:
    ChanEnd !(SegSource a)
            -- Both Chan ends must start with the same counter value.
            !AtomicCounter 
            -- the stream head; this must never point to a segment whose offset
            -- is greater than the counter value
            !(IORef (StreamHead a))
    deriving Typeable

data StreamHead a = StreamHead !Int !(Stream a)

--TODO later see if we get a benefit from the small array primops in 7.10,
--     which omit card-marking overhead and might have faster clone.
type StreamSegment a = P.MutableArray RealWorld (Cell a)

-- TRANSITIONS and POSSIBLE VALUES:
--   During Read:
--     Nothing
--     Just a
--   During Write:
--     Nothing   -> Just a
type Cell a = Maybe a

data Stream a = 
    Stream !(StreamSegment a)
           -- The next segment in the stream; new segments are allocated and
           -- put here as we go, with threads cooperating to allocate new
           -- segments:
           !(IORef (NextSegment a))

data NextSegment a = NoSegment | Next !(Stream a)

-- we expose `startingCellOffset` for debugging correct behavior with overflow:
newChanStarting :: Int -> IO (InChan a, OutChan a)
{-# INLINE newChanStarting #-}
newChanStarting !startingCellOffset = do
    segSource <- newSegmentSource
    stream <- Stream <$> segSource 
                     <*> newIORef NoSegment
    let end = ChanEnd segSource 
                  <$> newCounter (startingCellOffset - 1)
                  <*> newIORef (StreamHead startingCellOffset stream)
    inEnd@(ChanEnd _ _ inHeadRef) <- end
    finalizee <- newIORef True
    void $ mkWeakIORef inHeadRef $ do -- NOTE [1]
        -- make sure the array writes of any final writeChans occur before the
        -- following writeIORef:
        writeBarrier
        writeIORef finalizee False
    (,) (InChan finalizee inEnd) <$> (OutChan finalizee <$> end)
 -- [1] We no longer get blocked indefinitely exception in readers when all
 -- writers disappear, so we use finalizers. See also NOTE 1 in 'writeChan' and
 -- implementation of 'isActive' below.

-- | An action that returns @False@ sometime after the chan no longer has any
-- writers.
--
-- After @False@ is returned, any 'peekElement' which returns @Nothing@ can be
-- considered to be dead. Note that in the blocking implementations a
-- @BlockedIndefinitelyOnMVar@ exception is raised, so this function is
-- unnecessary.
isActive :: OutChan a -> IO Bool
isActive (OutChan finalizee _) = do
    b <- readIORef finalizee
    -- make sure that a peekElement that follows is not moved ahead:
    loadLoadBarrier 
    return b

-- TODO make a note here about our new 'stream' function :: OutChan a -> Stream a
-- TODO also implement a 'streamN' :: Int -> [Stream a]

-- | Duplicate a chan: the returned @OutChan@ begins empty, but data written to
-- the argument @InChan@ from then on will be available from both the original
-- @OutChan@ and the one returned here, creating a kind of broadcast channel.
dupChan :: InChan a -> IO (OutChan a)
{-# INLINE dupChan #-}
dupChan (InChan finalizee (ChanEnd segSource counter streamHead)) = do
    hLoc <- readIORef streamHead
    loadLoadBarrier
    wCount <- readCounter counter
    counter' <- newCounter wCount 
    streamHead' <- newIORef hLoc
    return $ OutChan finalizee $ ChanEnd segSource counter' streamHead'


-- | Write a value to the channel.
writeChan :: InChan a -> a -> IO ()
{-# INLINE writeChan #-}
writeChan (InChan _ ce@(ChanEnd segSource _ _)) = \a-> mask_ $ do 
    (segIx, (Stream seg next), maybeUpdateStreamHead) <- moveToNextCell ce
    P.writeArray seg segIx (Just a)
    maybeUpdateStreamHead  -- NOTE [1]
    -- try to pre-allocate next segment:
    when (segIx == 0) $ void $
      waitingAdvanceStream next segSource 0
 -- [1] We return the maybeUpdateStreamHead action from moveToNextCell rather
 -- than running it before returning, because we must ensure that the
 -- streamHead IORef is not GC'd (and its finalizer run) before the last
 -- element is written; else the user has no way of being sure that it has read
 -- the last element. See 'newChanStarting' and 'isActive'.


-- TODO or 'Item'? And something shorter than 'peeklement'?

-- | An idempotent @IO@ action that returns a particular enqueued element when
-- and if it becomes available. Each @Element@ corresponds to a particular
-- enqueued element, i.e. a returned @Element@ always offers the only means to
-- access one particular enqueued item.
newtype Element a = Element { peekElement :: IO (Maybe a) }

-- | Read an element from the chan, returning an @'Element' a@ future which
-- returns an actual element, when available, via 'peekElement'.
--
-- /Note re. exceptions/: When an async exception is raised during a @readChan@ 
-- the message that the read would have returned is likely to be lost, just as
-- it would be when raised directly after this function returns.
readChan :: OutChan a -> IO (Element a)
{-# INLINE readChan #-}
readChan (OutChan _ ce) = do  -- NOTE [1]
    (segIx, (Stream seg _), maybeUpdateStreamHead) <- moveToNextCell ce
    maybeUpdateStreamHead
    return $ Element $ P.readArray seg segIx
 -- [1] We don't need to mask exceptions here. We say that exceptions raised in
 -- readChan are linearizable as occuring just before we are to return with our
 -- element. Note that the two effects in moveToNextCell are to increment the
 -- counter (this is the point after which we lose the read), and set up any
 -- future segments required (all atomic operations).


-- | Like read which loops, calling 'yield' until an element becomes available,
-- or (like 'Control.Concurrent.Chan.Unagi.readChan' etc.) throwing a
-- 'BlockedIndefinitelyOnMVar' exception if the read is determined never to
-- succeed.
readChanYield :: OutChan a -> IO a
{-# INLINE readChanYield #-}
readChanYield oc = readChan oc >>= \el->
    let peekMaybe f = peekElement el >>= maybe f return 
        go = peekMaybe checkAndGo
        checkAndGo = do 
            b <- isActive oc
            if b then yield >> go
                 -- Do a necessary final check of the element:
                 else peekMaybe $ throwIO BlockedIndefinitelyOnMVar
     in go



-- TODO use moveToNextCell/waitingAdvanceStream from Unagi.hs, only we'd need
--      to parameterize those functions and types by 'Cell a' rather than 'a'.

-- increments counter, finds stream segment of corresponding cell (updating the
-- stream head pointer as needed), and returns the stream segment and relative
-- index of our cell.
moveToNextCell :: ChanEnd a -> IO (Int, Stream a, IO ())
{-# INLINE moveToNextCell #-}
moveToNextCell (ChanEnd segSource counter streamHead) = do
    (StreamHead offset0 str0) <- readIORef streamHead
#ifdef NOT_x86 
    -- fetch-and-add is a full barrier on x86; otherwise we need to make sure
    -- the read above occurrs before our fetch-and-add:
    loadLoadBarrier
#endif
    ix <- incrCounter 1 counter
    let (segsAway, segIx) = assert ((ix - offset0) >= 0) $ 
                 divMod_sEGMENT_LENGTH $! (ix - offset0)
              -- (ix - offset0) `quotRem` sEGMENT_LENGTH
        {-# INLINE go #-}
        go 0 str = return str
        go !n (Stream _ next) =
            waitingAdvanceStream next segSource (nEW_SEGMENT_WAIT*segIx)
              >>= go (n-1)
    str <- go segsAway str0
    let !maybeUpdateStreamHead = 
          when (segsAway > 0) $ do
            let !offsetN = 
                  offset0 + (segsAway `unsafeShiftL` lOG_SEGMENT_LENGTH) --(segsAway*sEGMENT_LENGTH)
            writeIORef streamHead $ StreamHead offsetN str
    return (segIx,str, maybeUpdateStreamHead)


-- thread-safely try to fill `nextSegRef` at the next offset with a new
-- segment, waiting some number of iterations (for other threads to handle it).
-- Returns nextSegRef's StreamSegment.
waitingAdvanceStream :: IORef (NextSegment a) -> SegSource a 
                     -> Int -> IO (Stream a)
waitingAdvanceStream nextSegRef segSource = go where
  go !wait = assert (wait >= 0) $ do
    tk <- readForCAS nextSegRef
    case peekTicket tk of
         NoSegment 
           | wait > 0 -> go (wait - 1)
             -- Create a potential next segment and try to insert it:
           | otherwise -> do 
               potentialStrNext <- Stream <$> segSource 
                                          <*> newIORef NoSegment
               (_,tkDone) <- casIORef nextSegRef tk (Next potentialStrNext)
               -- If that failed another thread succeeded (no false negatives)
               case peekTicket tkDone of
                 Next strNext -> return strNext
                 _ -> error "Impossible! This should only have been Next segment"
         Next strNext -> return strNext


-- copying a template array with cloneMutableArray is much faster than creating
-- a new one; in fact it seems we need this in order to scale, since as cores
-- increase we don't have enough "runway" and can't allocate fast enough:
type SegSource a = IO (StreamSegment a)

newSegmentSource :: IO (SegSource a)
newSegmentSource = do
    arr <- P.newArray sEGMENT_LENGTH Nothing
    return (P.cloneMutableArray arr 0 sEGMENT_LENGTH)

-- ----------
-- CELLS AND GC:
--
--   Each cell in a segment is assigned at most one reader and one writer
--
--   When all readers disappear and writers continue we'll have at most one
--   segment-worth of garbage that can't be collected at a time; when writers
--   advance the head segment pointer, the previous may be GC'd.
--
--   Readers blocked indefinitely should eventually raise a
--   BlockedIndefinitelyOnMVar.
-- ----------
