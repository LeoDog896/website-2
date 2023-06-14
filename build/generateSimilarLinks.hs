#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (unless)
import Data.Containers.ListUtils (nubOrd)
import Data.List (sort)
import qualified Control.Monad.Parallel as Par (mapM_)
import System.Environment (getArgs)
import Data.Map.Strict as M (fromList, lookup, keys, filter) -- restrictKeys, toList
-- import Data.Set as S (fromList)

import GenerateSimilar (embed, embeddings2Forest, findN, missingEmbeddings, readEmbeddings, similaritemExistsP, writeEmbeddings, writeOutMatch, pruneEmbeddings)
import qualified Config.GenerateSimilar as C (bestNEmbeddings, iterationLimit)
import LinkBacklink (readBacklinksDB)
import LinkMetadata (readLinkMetadata)
import Utils (printGreen)

maxEmbedAtOnce :: Int
maxEmbedAtOnce = 750

main :: IO ()
main = do md  <- readLinkMetadata
          let mdl = sort $ M.keys $ M.filter (\(_,_,_,_,_,abst) -> abst /= "") md -- to iterate over the annotation database's URLs, and skip outdated URLs still in the embedding database
          bdb <- readBacklinksDB
          edb <- readEmbeddings
          let edbDB = M.fromList $ map (\(a,b,c,d,e) -> (a,(b,c,d,e))) edb
          printGreen "Read databases."

          -- update for any missing embeddings, and return updated DB for computing distances & writing out fragments:
          let todo = take maxEmbedAtOnce $ sort $ missingEmbeddings md edb
          edb'' <- if null todo then printGreen "All databases up to date." >> return edb else
                     do
                       printGreen $ "Embedding…\n" ++ unlines (map show todo)
                       newEmbeddings <- mapM (embed edb md bdb) todo
                       printGreen "Generated embeddings."
                       let edb' = nubOrd (edb ++ newEmbeddings)
                       -- clean up by removing any outdated embeddings whose path/URL no longer corresponds to any annotations (typically because renamed):
                       let edb'' = pruneEmbeddings md edb'
                       writeEmbeddings edb''
                       printGreen "Wrote embeddings."
                       return edb''

          -- if we are only updating the embeddings, then we stop there and do nothing more. (This
          -- is useful for using `inotifywait` (from 'inotifytools' Debian package) to 'watch' the
          -- YAML databases for new entries, and immediately embed them then & there, so
          -- preprocess-markdown.hs's single-shot mode gets updated quickly with recently-written
          -- annotations, instead of always waiting for the nightly rebuild. When doing batches of
          -- new annotations, they are usually all relevant to each other, but won't appear in the
          -- suggested-links.)
          --
          -- eg. in a crontab, this would work:
          -- $ `@reboot screen -d -m -S "embed" bash -c 'cd ~/wiki/; while true; do inotifywait ~/wiki/metadata/*.yaml -e attrib && sleep 10s && date && runghc -istatic/build/ ./static/build/generateSimilarLinks.hs --only-embed; done'`
          --
          -- [ie.: 'at boot, start a background daemon which monitors the annotation files and
          -- whenever one is modified, kill the monitor, wait 10s, and check for new annotations to
          -- embed & save; if nothing, exit & restart the monitoring.']
          args <- getArgs
          -- Otherwise, we keep going & compute all the suggestions.
          -- rp-tree supports serializing the tree to disk, but unclear how to update it, and it's fast enough to construct that it's not a bottleneck, so we recompute it from the embeddings every time.
          ddb <- embeddings2Forest edb''
          unless (args == ["--only-embed"]) $ do
              printGreen "Begin computing & writing out missing similarity-rankings…"
              Par.mapM_ (\f -> do exists <- similaritemExistsP f
                                  unless exists $
                                               case M.lookup f edbDB of
                                                 Nothing        -> return ()
                                                 Just (b,c,d,e) -> do let nmatches = findN ddb C.bestNEmbeddings C.iterationLimit (f,b,c,d,e)
                                                                      writeOutMatch md bdb nmatches
                        )
                mdl
              printGreen "Wrote out missing."
              unless (args == ["--update-only-missing-embeddings"]) $ do
                printGreen "Rewriting all embeddings…"
                Par.mapM_ (writeOutMatch md bdb . findN ddb C.bestNEmbeddings C.iterationLimit) edb''
                Par.mapM_ (\f -> case M.lookup f edbDB of
                                       Nothing        -> return ()
                                       Just (b,c,d,e) -> writeOutMatch md bdb (findN ddb C.bestNEmbeddings C.iterationLimit (f,b,c,d,e))
                                      )
                  mdl
                printGreen "Done."

-- sortTagByTopic :: String -> IO [FilePath]
-- sortTagByTopic tag = do md  <- readLinkMetadata
--                         let mdl = M.keys $ M.filter (\(_,_,_,_,tags,abstract) -> tag `elem` tags && abstract /= "") md
--                         let seed = head mdl
--                         -- bdb <- readBacklinksDB
--                         edb <- readEmbeddings
--                         let edbDB = M.fromList $ map (\(a,b,c,d,e) -> (a,(b,c,d,e))) edb
--                         let edbDB' = M.restrictKeys edbDB (S.fromList mdl)
--                         let edb' = map (\(a,(b,c,d,e)) -> (a,b,c,d,e)) $ M.toList edbDB'
--                         ddb <- embeddings2Forest edb'
--                         undefined

-- lookupNextAndShrink results [] _ _ = results
-- lookupNextAndShrink results _ [] _ = results
-- lookupNextAndShrink accumulated remainingTargets remainingEmbeddings previous =
--   do ddb <- embeddings2Forest remainingEmbeddings
--      case M.lookup previous remainingEmbeddings of
--        Nothing        -> undefined
--        Just (b,c,d,e) -> do let match = head $ snd $ findN ddb 1 C.iterationLimit (previous,b,c,d,e)
--                             undefined
