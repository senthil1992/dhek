{-# LANGUAGE ForeignFunctionInterface #-}

--------------------------------------------------------------------------------
-- |
-- Module : Dhek.AppUtil
--
-- This module declares application utilities, 
-- related to Darwin/Mac OS X integration.
--
--------------------------------------------------------------------------------
module Dhek.AppUtil where

import Foreign.C

foreign import ccall "util.h nsappTerminate" appTerminate :: IO ()
foreign import ccall "util.h nsbrowserOpen" nsbrowserOpen :: CString -> IO ()

browserOpen :: String -> IO ()
browserOpen url = do
  curl <- newCString url
  nsbrowserOpen curl