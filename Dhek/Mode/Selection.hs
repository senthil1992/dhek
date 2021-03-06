{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
--------------------------------------------------------------------------------
-- |
-- Module : Dhek.Mode.Selection
--
--------------------------------------------------------------------------------
module Dhek.Mode.Selection (selectionModeManager) where

--------------------------------------------------------------------------------
import Prelude hiding (mapM_)
import Control.Applicative
import Data.Foldable (find, for_, foldMap, traverse_)
import Data.IORef
import Data.List ((\\), sortBy)
import Data.Maybe (isJust)
import Data.Traversable
import Foreign.Ptr

--------------------------------------------------------------------------------
import           Control.Lens      hiding (Action, act)
import           Control.Monad.RWS hiding (mapM_)
import           Control.Monad.State (evalState)
import qualified Data.IntMap                  as M
import qualified Graphics.Rendering.Cairo     as Cairo
import qualified Graphics.UI.Gtk              as Gtk

--------------------------------------------------------------------------------
import           Dhek.AppUtil (isKeyModifier, keyModifierName)
import           Dhek.Cartesian
import           Dhek.Engine.Instr
import           Dhek.Engine.Type
import           Dhek.Geometry
import           Dhek.GUI
import           Dhek.GUI.Action
import           Dhek.I18N
import           Dhek.Mode.Common.Draw
import qualified Dhek.Resources as Resources
import           Dhek.Types

--------------------------------------------------------------------------------
data Input
    = Input
      { inputGUI        :: GUI
      , inputAction     :: IORef (Maybe Action)
      , inputSelection  :: IORef (Maybe Rect)
      , inputTop        :: Gtk.ToolButton
      , inputDist       :: Gtk.ToolButton
      , inputDistCreate :: Gtk.ToolButton
      , inputRight      :: Gtk.ToolButton
      , inputBottom     :: Gtk.ToolButton
      , inputLeft       :: Gtk.ToolButton
      , inputHCenter    :: Gtk.ToolButton
      , inputVCenter    :: Gtk.ToolButton
      , inputDistVert   :: Gtk.ToolButton
      }

--------------------------------------------------------------------------------
data Action
    = Selection Vector2D
    | Xor (Maybe Vector2D)
    | Move [Rect] Vector2D

--------------------------------------------------------------------------------
newtype SelectionMode a
    = SelectionMode (RWST Input () EngineState IO a)
    deriving ( Functor
             , Applicative
             , Monad
             , MonadReader Input
             , MonadState EngineState
             , MonadIO
             )

--------------------------------------------------------------------------------
instance ModeMonad SelectionMode where
    mMove env
        = currentAction (return ()) (moveAction env)

    mPress env
        = do act <- currentAction (detectAction env) (pressAction env)
             setAction $ Just act

    mRelease _
        = currentAction (return ()) releaseAction

    mDrawing page ratio = do
        input <- ask
        rects <- engineStateGetRects
        mAct  <- getAction
        let gui = inputGUI input
        liftIO $ do
            rsSel <- gtkGetTreeAllSelection gui
            frame <- Gtk.widgetGetDrawWindow $ guiDrawingArea gui

            let width  = ratio * (pageWidth page)
                height = ratio * (pageHeight page)
                area   = guiDrawingArea gui

            Gtk.widgetSetSizeRequest area (truncate width) (truncate height)
            Gtk.renderWithDrawable frame $ do
                suf <- guiPdfSurface page ratio gui
                Cairo.setSourceSurface suf 0 0
                Cairo.paint

                Cairo.scale ratio ratio

                case mAct of
                    Just (Move rs v)
                        -> do traverse_ (drawRect selectedColor Line)
                                  (fmap (moveRect v) rs)
                              traverse_ (drawRect regularColor Line)
                                  (rects \\ rsSel)

                    _ -> do let selection = mAct >>= getSelectionRect
                            traverse_
                                (drawRectA selectionRColor selectionBColor Line)
                                selection
                            traverse_ (drawRect regularColor Line)
                                (rects \\ rsSel)
                            traverse_ (drawRect selectedColor Line) rsSel

      where
        regularColor   = rgbBlue
        selectedColor  = rgbRed
        selectionRColor = RGBA 0 0 0 0.18
        selectionBColor = RGBA 0 0 0 0.3

    mKeyPress kb
        = when (isKeyModifier $ kbKeyName kb) $
              do gui <- asks inputGUI
                 setAction $ Just $ Xor $ Nothing
                 liftIO $ gtkSetDhekCursor gui
                     (Just $ DhekCursor CursorSelectionUpdate)

    mKeyRelease _
        = do gui <- asks inputGUI
             liftIO $ gtkSetDhekCursor gui $ Just $ DhekCursor CursorSelection
             setAction Nothing

    mEnter = return ()

    mLeave = return ()

--------------------------------------------------------------------------------
moveAction :: DrawEnv -> Action -> SelectionMode ()
moveAction env act
    = do newAct <- go act
         setAction $ Just newAct
  where
    go (Move rs v)   = moveMove env rs v
    go (Selection v) = moveSelection env v
    go (Xor mV)      = moveXor env mV

--------------------------------------------------------------------------------
moveMove :: DrawEnv -> [Rect] -> Vector2D -> SelectionMode Action
moveMove env rs v = return $ Move rs newVect
  where
    pos     = drawPointer env
    newVect = v & vectorTo .~ pos

--------------------------------------------------------------------------------
moveSelection :: DrawEnv -> Vector2D -> SelectionMode Action
moveSelection env v = return $ Selection newVect
  where
    pos     = drawPointer env
    newVect = v & vectorTo .~ pos

--------------------------------------------------------------------------------
moveXor :: DrawEnv -> Maybe Vector2D -> SelectionMode Action
moveXor env mV = return $ Xor $ fmap go mV
  where
    pos  = drawPointer env
    go v = v & vectorTo .~ pos

--------------------------------------------------------------------------------
detectAction :: DrawEnv -> SelectionMode Action
detectAction env
    = do gui <- asks inputGUI
         rs  <- liftIO $ gtkGetTreeAllSelection gui
         if onMove rs
             then do liftIO $ gtkSetDhekCursor gui (Just $ GTKCursor Gtk.Hand1)
                     return $ Move rs newVect
             else return $ Selection newVect
  where
    pos        = drawPointer env
    newVect    = vector2D pos pos
    overedRect = getOverRect env

    onMove rs = isJust $
                    do o <- overedRect
                       find (sameId o) rs

    sameId a b = a ^. rectId == b ^. rectId

--------------------------------------------------------------------------------
pressAction :: DrawEnv -> Action -> SelectionMode Action
pressAction env act
    = case act of
          Xor _ -> return $ Xor $ Just newVect
          _     -> return act
  where
    pos     = drawPointer env
    newVect = vector2D pos pos

--------------------------------------------------------------------------------
releaseAction :: Action -> SelectionMode ()
releaseAction (Move rs v)   = releaseMove rs v
releaseAction (Selection v) = releaseSelection False v
releaseAction (Xor mV)      = releaseXor mV

--------------------------------------------------------------------------------
releaseMove :: [Rect] -> Vector2D -> SelectionMode ()
releaseMove rs v
    = do gui <- asks inputGUI
         engineStateSetRects newRs
         updateButtonsSensitivity newRs
         updateRectSelection newRs
         liftIO $ gtkSetDhekCursor gui $ Just $ DhekCursor CursorSelection
         setAction Nothing
  where
    newRs = fmap (moveRect v) rs

--------------------------------------------------------------------------------
releaseSelection :: Bool -> Vector2D -> SelectionMode ()
releaseSelection xor v
    = do gui   <- asks inputGUI
         rs    <- engineStateGetRects
         rsSel <- liftIO $ gtkGetTreeAllSelection gui

         -- get rectangles located in selection area
         let collected = foldMap (collectSelected rectSelection) rs
             crs = if xor
                   then let indexes = fmap ((^. rectId)) rsSel
                            m       = M.fromList (zip indexes rsSel)
                            m'      = foldl xOrSelection m collected in
                        M.elems m'
                   else collected

         liftIO $ gtkSetDhekCursor gui $ Just $ DhekCursor CursorSelection
         updateButtonsSensitivity crs
         updateRectSelection crs
         setAction Nothing
  where
    rectSelection = makeDrawSelectionRect v

    collectSelected r c
        | rectInArea c r = [c]
        | otherwise      = []

    xOrSelection m r
        = let go Nothing = Just r
              go _       = Nothing in
          M.alter go (r ^. rectId) m

--------------------------------------------------------------------------------
releaseXor :: Maybe Vector2D -> SelectionMode ()
releaseXor mV = traverse_ (releaseSelection True) mV

--------------------------------------------------------------------------------
getSelectionRect :: Action -> Maybe Rect
getSelectionRect (Selection v) = Just $ makeDrawSelectionRect v
getSelectionRect (Xor mV)      = fmap makeDrawSelectionRect mV
getSelectionRect _             = Nothing

--------------------------------------------------------------------------------
getAction :: SelectionMode (Maybe Action)
getAction
    = do ref <- asks inputAction
         liftIO $ readIORef ref

--------------------------------------------------------------------------------
currentAction :: SelectionMode a -> (Action -> SelectionMode a) -> SelectionMode a
currentAction def k
    = do input <- ask
         currentActionIO input def k

--------------------------------------------------------------------------------
currentActionIO :: MonadIO m
                => Input
                -> m a
                -> (Action -> m a)
                -> m a
currentActionIO input def k
    = do mTyp <- liftIO $ readIORef $ inputAction input
         maybe def k mTyp

--------------------------------------------------------------------------------
setAction :: Maybe Action -> SelectionMode ()
setAction mType
    = do ref <- asks inputAction
         liftIO $ writeIORef ref mType

--------------------------------------------------------------------------------
updateButtonsSensitivity :: [Rect] -> SelectionMode ()
updateButtonsSensitivity crs
    = do input <- ask
         liftIO $
             do Gtk.widgetSetSensitive (inputTop input) atLeast2
                Gtk.widgetSetSensitive (inputDist input) atLeast3
                Gtk.widgetSetSensitive (inputDistCreate input) cDistCreate
                Gtk.widgetSetSensitive (inputRight input) atLeast2
                Gtk.widgetSetSensitive (inputBottom input) atLeast2
                Gtk.widgetSetSensitive (inputLeft input) atLeast2
                Gtk.widgetSetSensitive (inputHCenter input) atLeast2
                Gtk.widgetSetSensitive (inputVCenter input) atLeast2
                Gtk.widgetSetSensitive (inputDistVert input) atLeast3
  where
    atLeast2    = length crs >= 2
    atLeast3    = length crs >= 3
    cDistCreate = canActiveDistCreate crs

--------------------------------------------------------------------------------
updateRectSelection :: [Rect] -> SelectionMode ()
updateRectSelection crs
    = do gui <- asks inputGUI
         liftIO $
            do gtkClearSelection gui
               for_ crs $ \cr ->
                   gtkSelectRect cr gui

--------------------------------------------------------------------------------
-- | Called when 'Top' button, located in mode's toolbar, is clicked
topButtonActivated :: EngineCtx m => GUI -> m ()
topButtonActivated gui = alignmentM gui AlignTop

--------------------------------------------------------------------------------
bottomButtonActivated :: EngineCtx m => GUI -> m ()
bottomButtonActivated gui = alignmentM gui AlignBottom

--------------------------------------------------------------------------------
rightButtonActivated :: EngineCtx m => GUI -> m ()
rightButtonActivated gui = alignmentM gui AlignRight

--------------------------------------------------------------------------------
leftButtonActivated :: EngineCtx m => GUI -> m ()
leftButtonActivated gui = alignmentM gui AlignLeft

--------------------------------------------------------------------------------
alignmentM :: EngineCtx m => GUI -> Align -> m ()
alignmentM gui align
    = do rs <- liftIO $ gtkGetTreeAllSelection gui
         let rs' = alignment align rs

         engineStateSetRects rs'
         forM_ rs' $ \r ->
             liftIO $ gtkSelectRect r gui
         engineEventStack %= (UpdateRectPos:)
         liftIO $ Gtk.widgetQueueDraw $ guiDrawingArea gui

--------------------------------------------------------------------------------
data Align
    = AlignTop
    | AlignRight
    | AlignBottom
    | AlignLeft
    | AlignHCenter
    | AlignVCenter

--------------------------------------------------------------------------------
data Bin a b = Bin !a !b

--------------------------------------------------------------------------------
alignment :: Align -> [Rect] -> [Rect]
alignment align rects
    | (x:xs) <- rects =
        case align of
            AlignTop     -> go id topCmp topUpd x xs
            AlignRight   -> go id rightCmp rightUpd x xs
            AlignBottom  -> go id bottomCmp bottomUpd x xs
            AlignLeft    -> go id leftCmp leftUpd x xs
            AlignHCenter -> go hcInit hcCmp hcUpd x xs
            AlignVCenter -> go vcInit vcCmp vcUpd x xs

    | otherwise = []

  where
    go initK cmpK updK r rs
        = let res = foldr cmpK (initK r) rs in
          fmap (updK res) rects

    -- Top
    topCmp r1 r2
        | r1 ^. rectY < r2 ^. rectY = r1
        | otherwise                 = r2

    topUpd toppest r
        = r & rectY .~ (toppest ^. rectY)

    --Right
    rightCmp r1 r2
        | r1 ^. rectX + r1 ^. rectWidth > r2 ^. rectX + r2 ^. rectWidth = r1
        | otherwise = r2

    rightUpd rightest r
        = r & rectX +~ delta
      where
        rmx   = r ^. rectX + r ^. rectWidth
        mx    = rightest ^. rectX + rightest ^. rectWidth
        delta = mx - rmx

    -- Bottom
    bottomCmp r1 r2
        | r1 ^. rectY + r1 ^. rectHeight > r2 ^. rectY + r2 ^. rectHeight = r1
        | otherwise = r2

    bottomUpd bottomest r
        = r & rectY +~ delta
      where
        rmy   = r ^. rectY + r ^. rectHeight
        my    = bottomest ^. rectY + bottomest ^. rectHeight
        delta = my - rmy

    -- Left
    leftCmp r1 r2
        | r1 ^. rectX < r2 ^. rectX = r1
        | otherwise                 = r2

    leftUpd leftest r
        = r & rectX .~ (leftest ^. rectX)

    -- Horizontal Center
    lenX r = r ^. rectX + r ^. rectWidth

    hcInit r =
        Bin (r ^. rectX) (lenX r)

    hcCmp r (Bin leftest rightest)
        = let newLeftest = if r ^. rectX < leftest
                           then r ^. rectX
                           else leftest

              newRightest = if lenX r > rightest
                            then lenX r
                            else rightest in

          Bin newLeftest newRightest

    hcUpd (Bin leftest rightest) r
        = r & rectX .~ center - (r ^. rectWidth / 2)
      where
        len    = rightest - leftest
        center = leftest + len / 2

    -- Vertical Center
    lenY r = r ^. rectY + r ^. rectHeight

    vcInit r =
        Bin (r ^. rectY) (lenY r)

    vcCmp r (Bin toppest bottomest)
        = let newToppest = if r ^. rectY < toppest
                           then r ^. rectY
                           else toppest

              newBottomest = if lenY r > bottomest
                             then lenY r
                             else bottomest in

          Bin newToppest newBottomest

    vcUpd (Bin toppest bottomest) r
        = r & rectY .~ center - (r ^. rectHeight / 2)
      where
        len    = bottomest - toppest
        center = toppest + len / 2

--------------------------------------------------------------------------------
distributing :: Lens Rect Rect Double Double
             -> Lens Rect Rect Double Double
             -> [Rect]
             -> [Rect]
distributing _ _ [] = []
distributing ldim llen rs@(_:_)
    = _L:(evalState action _L) -- homogeneous-spaced rectangle list
  where
    sumLenF r s = s + realToFrac (r ^. llen)

    compareDimF a b
        = compare (a ^. ldim) (b ^. ldim)

    sorted = sortBy compareDimF rs
    _AN = fromIntegral $ length rs -- number of selected area
    _AW = foldr sumLenF 0 rs -- selected areas width summed
    _L  = head sorted -- most left rectangle
    _R  = last sorted -- most right rectangle
    _D  = _R ^. ldim - _L ^. ldim + _R ^. llen -- _L and _R distance
    _S  = (_D - _AW) / (_AN - 1) -- space between rectangles
    action = for (tail sorted) $ \r ->
        do _P <- get
           let _I = _P ^. ldim + _P ^. llen
               r' = r & ldim .~ _I + _S
           put r'
           return r'

--------------------------------------------------------------------------------
distributingM :: EngineCtx m
              => GUI
              -> Lens Rect Rect Double Double
              -> Lens Rect Rect Double Double
              -> m ()
distributingM gui ldim llen
    = do rs <- liftIO $ gtkGetTreeAllSelection gui
         let spaced = distributing ldim llen rs

         engineStateSetRects spaced
         forM_ spaced $ \r ->
             liftIO $ gtkSelectRect r gui
         engineEventStack %= (UpdateRectPos:)
         liftIO $ Gtk.widgetQueueDraw $ guiDrawingArea gui

--------------------------------------------------------------------------------
distVerticalActivated :: EngineCtx m => GUI -> m ()
distVerticalActivated gui
    = distributingM gui rectY rectHeight

--------------------------------------------------------------------------------
-- | Called when 'Distribute' button, located in mode's toolbar, is clicked
distButtonActivated :: EngineCtx m => GUI -> m ()
distButtonActivated gui
    = distributingM gui rectX rectWidth

--------------------------------------------------------------------------------
-- | Called when 'Distribute create' button, located in mode's toolbar,
--   is clicked
distCreateButtonActivated :: EngineCtx m => GUI -> m ()
distCreateButtonActivated gui
    = do sel <- liftIO $ gtkGetTreeAllSelection gui
         let (r0:r1:rn:_) = sortBy rectCompareIndex sel
             y    = r0 ^. rectY
             w    = r0 ^. rectWidth
             h    = r0 ^. rectHeight
             name = r0 ^. rectName
             s -- Horizontal space between 0 & 1
                 = r1 ^. rectX - (r0 ^. rectX + w)
             d -- Distance between left of 1 & right of N
                 = rn ^. rectX - (r1 ^. rectX + w + s)
             m -- Number of cells to be created between cell 1 & N
                 = floor (((realToFrac d) / realToFrac (w + s) :: Double))
             rn' -- N index is updated according to 'm' new rectangles
                 = rn & rectIndex ?~ m+2 -- 'm' rect after 2nd rect(1) + 1

             -- Create 'm' new rectangles
             loop _ _ []
                 = return ()
             loop prevRect idx (_:rest)
                 = do rid <- engineDrawState.drawFreshId <+= 1
                      let rx = prevRect ^. rectX + prevRect ^. rectWidth + s
                          pt = point2D rx y
                          r  = rectNew pt h w & rectId    .~ rid
                                              & rectName  .~ name
                                              & rectType  .~ "textcell"
                                              & rectIndex ?~ idx
                      engineStateSetRect r
                      liftIO $ gtkAddRect r gui
                      loop r (idx+1) rest

         loop r1 2 (replicate m ())
         engineStateSetRect rn'

--------------------------------------------------------------------------------
hCenterActivated :: EngineCtx m => GUI -> m ()
hCenterActivated gui = alignmentM gui AlignHCenter

--------------------------------------------------------------------------------
vCenterActivated :: EngineCtx m => GUI -> m ()
vCenterActivated gui = alignmentM gui AlignVCenter

--------------------------------------------------------------------------------
-- | Dist create button is enabled if only 3 textcells with same name property
--   are selected, and if indexes of these cells are 0, 1 and N>2.
canActiveDistCreate :: [Rect] -> Bool
canActiveDistCreate rs@(_:_:_:[])
    = let (r0:r1:rn:_) = sortBy rectCompareIndex rs
          areTextcell  = all ((== "textcell") . (^. rectType)) rs
          sameName     = all ((== r0 ^. rectName) . (^. rectName)) [r1,rn] in
      areTextcell               &&
      r0 ^. rectIndex == Just 0 &&
      r1 ^. rectIndex == Just 1 &&
      rn ^. rectIndex >  Just 1 &&
      sameName
canActiveDistCreate _
    = False

--------------------------------------------------------------------------------
runSelection :: Input -> SelectionMode a -> EngineState -> IO EngineState
runSelection input (SelectionMode m) s
    = do (s', _) <- execRWST m input s
         return s'

--------------------------------------------------------------------------------
selectionMode :: Input -> Mode
selectionMode input = Mode (runSelection input . runM)

--------------------------------------------------------------------------------
selectionModeManager :: ((forall m. EngineCtx m => m ()) -> IO ())
                     -> GUI
                     -> IO ModeManager
selectionModeManager handler gui = do
    Gtk.treeSelectionSetMode (guiRectTreeSelection gui) Gtk.SelectionMultiple

    vsep1 <- Gtk.separatorToolItemNew
    Gtk.separatorToolItemSetDraw vsep1 False
    Gtk.toolbarInsert toolbar vsep1 (-1)
    Gtk.widgetShowAll vsep1

    -- Top button
    btop <- createToolbarButton gui Resources.alignVerticalTop
    cid <- Gtk.onToolButtonClicked btop $ handler $ topButtonActivated gui

    -- Vertical Center button
    bvcenter <- createToolbarButton gui Resources.alignVerticalCenter
    bvid     <- Gtk.onToolButtonClicked bvcenter $ handler $
                vCenterActivated gui

    -- Bottom button
    bbottom <- createToolbarButton gui Resources.alignVerticalBottom
    bbid    <- Gtk.onToolButtonClicked bbottom $ handler $
               bottomButtonActivated gui

    -- Left button
    bleft <- createToolbarButton gui Resources.alignHorizontalLeft
    lid   <- Gtk.onToolButtonClicked bleft $ handler $
             leftButtonActivated gui

    -- Horizontal Center button
    bhcenter <- createToolbarButton gui Resources.alignHorizontalCenter
    bhid     <- Gtk.onToolButtonClicked bhcenter $ handler $
                hCenterActivated gui

    -- Right button
    bright <- createToolbarButton gui Resources.alignHorizontalRight
    rid    <- Gtk.onToolButtonClicked bright $ handler $
              rightButtonActivated gui

    vsep2 <- Gtk.separatorToolItemNew
    Gtk.separatorToolItemSetDraw vsep2 False
    Gtk.toolbarInsert toolbar vsep2 (-1)
    Gtk.widgetShowAll vsep2

    -- Distribute vertical
    bdistv <- createToolbarButton gui Resources.distributeVertical
    dvid   <- Gtk.onToolButtonClicked bdistv $ handler $
              distVerticalActivated gui

    -- Distribute button
    bdist <- createToolbarButton gui Resources.distribute
    did   <- Gtk.onToolButtonClicked bdist $ handler $ distButtonActivated gui

    -- Distribute create button
    bdistcreate <- createToolbarButton gui Resources.distributeCreate
    dcid        <- Gtk.onToolButtonClicked bdistcreate $ handler $
                   distCreateButtonActivated gui

    refAction <- newIORef Nothing
    refSel    <- newIORef Nothing

    let input = Input
                { inputGUI        = gui
                , inputAction     = refAction
                , inputSelection  = refSel
                , inputTop        = btop
                , inputDist       = bdist
                , inputDistCreate = bdistcreate
                , inputRight      = bright
                , inputBottom     = bbottom
                , inputLeft       = bleft
                , inputHCenter    = bhcenter
                , inputVCenter    = bvcenter
                , inputDistVert   = bdistv
                }

    -- Display selection Help message
    Gtk.statusbarPop (guiStatusBar gui) (guiContextId gui)
    _ <- Gtk.statusbarPush (guiStatusBar gui) (guiContextId gui)
         (guiTranslate gui $ MsgSelectionHelp keyModifierName)

    liftIO $ gtkSetDhekCursor gui
        (Just $ DhekCursor $ CursorSelection)

    return $ ModeManager (selectionMode input) $
        liftIO $ do Gtk.signalDisconnect cid
                    Gtk.signalDisconnect did
                    Gtk.signalDisconnect dcid
                    Gtk.signalDisconnect rid
                    Gtk.signalDisconnect bbid
                    Gtk.signalDisconnect lid
                    Gtk.signalDisconnect bhid
                    Gtk.signalDisconnect bvid
                    Gtk.signalDisconnect dvid

                    Gtk.containerForeach toolbar $ \w ->
                        do i <- Gtk.toolbarGetItemIndex toolbar $
                                Gtk.castToToolItem w
                           if i == 0
                               then return ()
                               else Gtk.containerRemove toolbar w

                    Gtk.treeSelectionSetMode (guiRectTreeSelection gui)
                        Gtk.SelectionSingle

                    gtkSetDhekCursor gui Nothing
  where
    toolbar = guiModeToolbar gui

--------------------------------------------------------------------------------
createToolbarButton :: GUI -> Ptr Gtk.InlineImage -> IO Gtk.ToolButton
createToolbarButton gui img
    = do bimg <- loadImage img
         b   <- Gtk.toolButtonNew (Just bimg) (Nothing :: Maybe String)
         Gtk.toolbarInsert (guiModeToolbar gui) b (-1)
         Gtk.widgetShowAll b
         Gtk.widgetSetSensitive b False
         return b

--------------------------------------------------------------------------------
-- | Utilities
--------------------------------------------------------------------------------
rectInArea :: Rect -- target
           -> Rect -- area
           -> Bool
rectInArea t a = tx      >= ax      &&
                 ty      >= ay      &&
                 (tx+tw) <= (ax+aw) &&
                 (ty+th) <= (ay+ah)
  where
    tx = t ^. rectX
    ty = t ^. rectY
    tw = t ^. rectWidth
    th = t ^. rectHeight

    ax = a ^. rectX
    ay = a ^. rectY
    aw = a ^. rectWidth
    ah = a ^. rectHeight
