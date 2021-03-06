{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

import Control.Monad
import Control.Concurrent
import Control.Exception
import Data.Data
import Data.Generics
import Data.List
import Data.IORef
import Data.Maybe
import Data.Time.Clock
import Data.Time.LocalTime
import System.Directory (doesFileExist)
import System.Environment
import System.IO
import Text.Blaze.Html5 as Html5
import Text.Blaze.Html5.Attributes as Attr
import Text.Blaze.Html.Renderer.String
import Text.Pandoc
import Text.Pandoc.Highlighting
import Text.Printf

writeHTML5SlideString :: WriterOptions -> Pandoc -> String
writeHTML5SlideString opt pdoc = do
  renderHtml $ writeHTML5Slide opt pdoc

writeHTML5Slide :: WriterOptions -> Pandoc -> Html
writeHTML5Slide opt (Pandoc Meta {..} blocks) = do
  html $ do
    Html5.head $ do
      Html5.title $ do
        mapM_ renderInline $ everywhere (mkT $ replace "<br>" " ") docTitle
      Html5.meta ! charset "utf-8"
      script ! src "http://html5slides.googlecode.com/svn/trunk/slides.js" $ return ()
      link ! rel "stylesheet" ! href (toValue hlCssFilename)
      link ! rel "stylesheet" ! href "style.css"

    Html5.body ! Attr.style "display: none" $ do
      section ! class_ "slides layout-regular template-pfi" $ do
        article $ do
          h1 $ mapM_ renderInline docTitle
          p $ do
            forM_ docAuthors $ \author ->
              mapM_ renderInline author
            br
            mapM_ renderInline docDate

        forM_ (sectionize blocks) $ \sec -> do
          article $ do
            mapM_ renderBlock sec

sectionize :: [Block] -> [[Block]]
sectionize [] = []
sectionize (b:bs) =
  let (cs, ds) = Prelude.span (not . isSplitter) bs
  in (b:cs) : sectionize ds

isSplitter (Header _ _) = True
isSplitter _ = False

sc :: String
sc = "\"sourceCode\""

replace :: String -> String -> String -> String
replace _ _ "" = ""
replace from to ss
  | from `isPrefixOf` ss = to ++ drop (length from) ss
  | otherwise = Prelude.head ss : replace from to (tail ss)

renderBlock :: Block -> Html
renderBlock block = case block of
  Plain     inls -> mapM_ renderInline inls
  Para      inls -> p $ mapM_ renderInline inls
  
  CodeBlock attr codestr -> do
    fromMaybe (pre $ toMarkup codestr) $
      highlight formatHtmlBlock attr' codestr
    where
      (is, cs, kvs) = attr
      attr' = (is, "noprettyprint" : cs, kvs)  -- Prevent html5slides from highlighting code too.
  
  RawBlock  format str -> preEscapedToMarkup str
  BlockQuote blocks -> blockquote $ mapM_ renderBlock blocks
  OrderedList attr bss -> do
    ol $ do
      forM_ bss $ \bs -> do
        li $ mapM_ renderBlock bs
  BulletList bss -> do
    ul $ do
      forM_ bss $ \bs -> do
        li $ mapM_ renderBlock bs
  DefinitionList defs -> do
    dl $ do
      forM_ defs $ \(t, ds) -> do
        dd $ mapM_ renderInline t
        forM_ ds $ \d ->
          mapM_ renderBlock d
  Header level inls -> do
    let h = case level of
          1 -> h1
          2 -> h2
          3 -> h3
          4 -> h4
          5 -> h5
          6 -> h6
          _ -> error ("header level: " ++ show level)
    h $ mapM_ renderInline inls
  HorizontalRule -> hr
  Table cap colAlign colWidthRatio colHeader rows -> do
    table $ do
      caption $ mapM_ renderInline cap
      thead $ tr $ do
        forM_ colHeader $ \co -> td $ do
          mapM_ renderBlock co
      tbody $ do
        forM_ rows $ \row -> tr $ do
          forM_ row $ \co -> td $ do
            mapM_ renderBlock co
  Null ->
    return ()

renderInline :: Inline -> Html
renderInline inl = case inl of
  Str ss ->
    toHtml ss
  Emph inls ->
    em $ mapM_ renderInline inls
  Strong inls ->
    strong $ mapM_ renderInline inls
  Strikeout inls ->
    del $ mapM_ renderInline inls
  Superscript inls ->
    sup $ mapM_ renderInline inls
  Subscript inls ->
    sub $ mapM_ renderInline inls
  SmallCaps inls ->
    small $ mapM_ renderInline inls
  Quoted SingleQuote inls -> do
    toHtml ("'" :: String)
    mapM_ renderInline inls
    toHtml ("'" :: String)
  Quoted DoubleQuote inls -> do
    toHtml ("\"" :: String)
    mapM_ renderInline inls
    toHtml ("\"" :: String)
  Cite cs inls -> do
    Html5.cite $ mapM_ renderInline inls
  Code ([], ["url"], []) code ->
    toHtml code
  Code attr code ->
    error $ show attr
  Space -> preEscapedToMarkup ("&nbsp;" :: String)
  LineBreak -> br
  Math mathType str -> error "math"
  RawInline "html" str -> preEscapedToMarkup str
  RawInline format str -> error ("rawinline: " ++ format)
  Link inls (url, title) -> do
    a ! href (toValue url) ! alt (toValue title) $
      mapM_ renderInline inls
  Image inls (url, title) -> do
    img ! src (toValue url) ! alt (toValue title) ! class_ "centered"
  Note _ -> error "note not supported"

main :: IO ()
main = do
  [filename] <- getArgs
  let outname = (++".html") $ takeWhile (/='.') filename
  r <- newIORef ""
  forever $ do
    try_  $ do
      -- CSS
      hlCssFileExists <- doesFileExist hlCssFilename
      unless hlCssFileExists $ do
        writeFile hlCssFilename $ styleToCss pygments
        logPutStrLn $ "create \"" ++ hlCssFilename ++ "\""
      -- Slide
      strsrc <- readFile filename
      bef <- readIORef r
      when (bef /= strsrc) $ do
        let doc = readMarkdown defaultParserState { stateStandalone = True } strsrc
        writeFile outname $
          writeHTML5SlideString defaultWriterOptions doc
        writeIORef r strsrc
        logPutStrLn "update"
    threadDelay $ 10^(6::Int)

try_ :: IO a -> IO ()
try_ m = do
  ret <- try m
  case ret of
    Left (SomeException e) -> do
      print e
    Right _ ->
      return ()

hlCssFilename :: String
hlCssFilename = "syntax.css"

getCurrentLocalTime :: IO LocalTime
getCurrentLocalTime = do
  cur <- getCurrentTime
  tz <- getCurrentTimeZone
  return $ utcToLocalTime tz cur

logPutStrLn :: String -> IO ()
logPutStrLn xs = do
  lt <- getCurrentLocalTime
  printf "[%s]: %s\n" (show lt) xs
  hFlush stdout
