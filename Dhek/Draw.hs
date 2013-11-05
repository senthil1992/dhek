module Dhek.Draw where

import Prelude hiding (mapM_)

import Control.Lens ((^.), use)
import Control.Monad.RWS hiding (mapM_)

import System.CPUTime
import Data.Foldable (mapM_)

import qualified Graphics.Rendering.Cairo     as Cairo
import qualified Graphics.UI.Gtk              as Gtk
import qualified Graphics.UI.Gtk.Poppler.Page as Poppler

import Dhek.Engine
import Dhek.Types

gtkDraw :: EngineCallback Drawing
gtkDraw d = do
    env       <- ask
    selected  <- use engineSelected
    selection <- use engineSelection
    event     <- use engineEvent
    liftIO $ do
        cpu <- getCPUTime
        print ("Drawing: " ++ show cpu)
        frame     <- Gtk.widgetGetDrawWindow area
        (fw',fh') <- Gtk.drawableGetSize frame
        let width  = ratio * (pageWidth page)
            height = ratio * (pageHeight page)
            fw     = fromIntegral fw'
            fh     = fromIntegral fh'
            overed = _engineOverRect env
            rects  = _engineRects env
            eventR = event >>= eventGetRect
        Gtk.widgetSetSizeRequest area (truncate width) (truncate height)
        Gtk.renderWithDrawable frame $ do
            Cairo.setSourceRGB 1.0 1.0 1.0
            Cairo.rectangle 0 0 fw fh
            Cairo.fill
            Cairo.scale ratio ratio
            Poppler.pageRender (pagePtr page)
            --mapM_ (drawGuide fW fH) guides
            --mapM_ (drawGuide fW fH) curGuide
            Cairo.closePath
            Cairo.stroke
            drawRects 1.0 selected overed rects
            drawingSel selection
            drawRects 1.0 Nothing eventR eventR
  where
    area  = drawingArea d
    ratio = drawingRatio d
    page  = drawingPage d

    drawRects th sel ove = mapM_ (drawing th sel ove)

    drawing th sel ove r =
        let x = r ^. rectX
            y = r ^. rectY
            h = r ^. rectHeight
            w = r ^. rectWidth
            onSel s
                | s == r    = Cairo.setSourceRGB 1.0 0 0
                | otherwise = return ()
            onOver o
                | o == r    = Cairo.setSourceRGB 0.16 0.72 0.92
                | otherwise = return ()
            step _ = Cairo.setSourceRGB 0 0 1.0 in
        do Cairo.setSourceRGB 0 0 1.0
           mapM_ onOver ove
           mapM_ onSel sel
           Cairo.setLineWidth th
           Cairo.rectangle x y w h
           Cairo.closePath
           Cairo.stroke

    drawingSel = mapM_ go
      where
        go r =
            let x = r ^. rectX
                y = r ^. rectY
                h = r ^. rectHeight
                w = r ^. rectWidth in
            do Cairo.setSourceRGB 0 1.0 0
               Cairo.setLineWidth 1
               Cairo.rectangle x y w h
               Cairo.closePath
               Cairo.stroke