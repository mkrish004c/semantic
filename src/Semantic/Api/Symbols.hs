{-# LANGUAGE MonoLocalBinds, RankNTypes #-}
module Semantic.Api.Symbols
  ( legacyParseSymbols
  , parseSymbols
  , parseSymbolsBuilder
  ) where

import           Control.Effect.Error
import           Control.Effect.Parse
import           Control.Effect.Reader
import           Control.Exception
import           Control.Lens
import           Data.Blob hiding (File (..))
import           Data.ByteString.Builder
import           Data.Language
import           Data.Term
import qualified Data.Text as T
import qualified Data.Vector as V
import           Data.Text (pack)
import qualified Language.Python as Python
import qualified Parsing.Parser as Parser
import           Prologue
import           Semantic.Api.Bridge
import qualified Semantic.Api.LegacyTypes as Legacy
import           Semantic.Proto.SemanticPB hiding (Blob)
import           Semantic.Config
import           Semantic.Task
import           Serializing.Format (Format)
import           Source.Loc
import           Source.Source
import           Tags.Taggable
import           Tags.Tagging
import qualified Tags.Tagging.Precise as Precise

legacyParseSymbols :: (Member Distribute sig, Member (Error SomeException) sig, Member (Reader PerLanguageModes) sig, Member Parse sig, Carrier sig m, Traversable t) => t Blob -> m Legacy.ParseTreeSymbolResponse
legacyParseSymbols blobs = Legacy.ParseTreeSymbolResponse <$> distributeFoldMap go blobs
  where
    go :: (Member (Error SomeException) sig, Member (Reader PerLanguageModes) sig, Member Parse sig, Carrier sig m) => Blob -> m [Legacy.File]
    go blob@Blob{..} = doParse (pure . renderToSymbols) blob `catchError` (\(SomeException _) -> pure (pure emptyFile))
      where
        emptyFile = tagsToFile []

        -- Legacy symbols output doesn't include Function Calls.
        symbolsToSummarize :: [Text]
        symbolsToSummarize = ["Function", "Method", "Class", "Module"]

        renderToSymbols :: ToTags t => t Loc -> [Legacy.File]
        renderToSymbols = pure . tagsToFile . tags (blobLanguage blob) symbolsToSummarize blobSource

        tagsToFile :: [Tag] -> Legacy.File
        tagsToFile tags = Legacy.File (pack (blobPath blob)) (pack (show (blobLanguage blob))) (fmap tagToSymbol tags)

        tagToSymbol :: Tag -> Legacy.Symbol
        tagToSymbol Tag{..}
          = Legacy.Symbol
          { symbolName = name
          , symbolKind = pack (show kind)
          , symbolLine = line
          , symbolSpan = converting #? span
          }

parseSymbolsBuilder :: (Member Distribute sig, Member (Error SomeException) sig, Member Parse sig, Member (Reader Config) sig, Member (Reader PerLanguageModes) sig, Carrier sig m, Traversable t) => Format ParseTreeSymbolResponse -> t Blob -> m Builder
parseSymbolsBuilder format blobs = parseSymbols blobs >>= serialize format

parseSymbols :: (Member Distribute sig, Member (Error SomeException) sig, Member (Reader PerLanguageModes) sig, Member Parse sig, Carrier sig m, Traversable t) => t Blob -> m ParseTreeSymbolResponse
parseSymbols blobs = ParseTreeSymbolResponse . V.fromList . toList <$> distributeFor blobs go
  where
    go :: (Member (Error SomeException) sig, Member (Reader PerLanguageModes) sig, Member Parse sig, Carrier sig m) => Blob -> m File
    go blob@Blob{..} = catching $ doParse (pure . renderToSymbols) blob
      where
        catching m = m `catchError` (\(SomeException e) -> pure $ errorFile (show e))
        blobLanguage' = blobLanguage blob
        blobPath' = pack $ blobPath blob
        errorFile e = File blobPath' (bridging # blobLanguage') mempty (V.fromList [ParseError (T.pack e)]) blobOid

        renderToSymbols :: ToTags t => t Loc -> File
        renderToSymbols term = tagsToFile (tags (blobLanguage blob) symbolsToSummarize blobSource term)

        tagsToFile :: [Tag] -> File
        tagsToFile tags = File blobPath' (bridging # blobLanguage') (V.fromList (fmap tagToSymbol tags)) mempty blobOid

symbolsToSummarize :: [Text]
symbolsToSummarize = ["Function", "Method", "Class", "Module", "Call", "Send"]

tagToSymbol :: Tag -> Symbol
tagToSymbol Tag{..} = Symbol
  { symbol = name
  , kind = pack (show kind)
  , line = line
  , span = converting #? span
  , docs = fmap Docstring docs
  }


class ToTags t where
  tags :: Language -> [Text] -> Source -> t Loc -> [Tag]

instance IsTaggable syntax => ToTags (Term syntax) where
  tags = runTagging

instance ToTags Python.Term where
  tags _ _ = Precise.tags


doParse
  :: ( Carrier sig m
     , Member (Error SomeException) sig
     , Member Parse sig
     , Member (Reader PerLanguageModes) sig
     )
  => (forall t . ToTags t => t Loc -> m a)
  -> Blob
  -> m a
doParse with blob = do
  modes <- ask @PerLanguageModes
  case blobLanguage blob of
    Go         -> parse Parser.goParser         blob >>= with
    Haskell    -> parse Parser.haskellParser    blob >>= with
    JavaScript -> parse Parser.tsxParser        blob >>= with
    JSON       -> parse Parser.jsonParser       blob >>= with
    JSX        -> parse Parser.tsxParser        blob >>= with
    Markdown   -> parse Parser.markdownParser   blob >>= with
    Python
      | Precise <- pythonMode modes -> parse Parser.precisePythonParser blob >>= with
      | otherwise                   -> parse Parser.pythonParser        blob >>= with
    Ruby       -> parse Parser.rubyParser       blob >>= with
    TypeScript -> parse Parser.typescriptParser blob >>= with
    TSX        -> parse Parser.tsxParser        blob >>= with
    PHP        -> parse Parser.phpParser        blob >>= with
    _          -> noLanguageForBlob (blobPath blob)
