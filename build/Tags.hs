{-# LANGUAGE OverloadedStrings #-}
module Tags where

import Control.Monad (filterM, unless)
import Data.Char (toLower)
import Data.Containers.ListUtils (nubOrd)
import Data.List (isSuffixOf, isInfixOf, isPrefixOf, sort, intersperse)
import System.Directory (doesFileExist)
import System.Directory.Recursive (getDirFiltered, getSubdirsRecursive) -- dir-traverse
import System.FilePath (takeDirectory)
import Text.Pandoc (Inline(Str, RawInline, Link, Span), Format(..), Block(Para, Div), nullAttr)
import qualified Data.Map.Strict as M (elems, map, toList )
import qualified Data.Text as T (append, pack, unpack, Text)

import LinkMetadataTypes (Metadata)
import Utils (anyInfix, replace, sed, sedMany, trim, split, replaceMany, frequency, pairs, fixedPoint, isUniqueKeys, isUniqueList, isUniqueAll, isCycleLess)

-- Remind to refine link tags: should be <100. (We count using the annotation database instead of counting files inside each directory because so many are now cross-tagged or virtual.)
tagMax, tagPairMax :: Int
tagMax = 100
tagPairMax = 11
tagCount :: Metadata -> [(Int,String)]
tagCount = frequency . concatMap (\(_,(_,_,_,_,tags,_)) -> tags) . M.toList
tagPairsCount :: Metadata -> [(Int,(String,String))]
tagPairsCount md = reverse $ frequency $ concatMap pairs $ M.elems $ M.map (\(_,_,_,_,ts,abst) -> if null abst || null ts then [] else ts) md

-- Compile tags down into a Span containing a list of links to the respective /doc/ directory indexes which will contain a copy of all annotations corresponding to that tag/directory.
--
-- Simple version:
-- > tagsToLinksSpan "economics genetics/heritable psychology/writing"
-- →
-- Span ("",["link-tags"],[])
--   [Link ("",["link-tag"],[]) [Str "economics"] ("/doc/economics/index",""),Str ", ",
--     Link ("",["link-tag"],[]) [Str "genetics/heritable"] ("/doc/genetics/heritable/index",""),Str ", ",
--     Link ("",["link-tag"],[]) [Str "psychology/writing"] ("/doc/psychology/writing/index","")
--   ]
-- Markdown:
-- →
-- [[economics](/doc/economics/index){.link-tag}, [genetics/heritable](/doc/genetics/heritable/index){.link-tag}, [psychology/writing](/doc/psychology/writing/index){.link-tag}]{.link-tags}
-- HTML:
-- →
-- <span class="link-tags">
--   <a href="/doc/economics/index" class="link-tag">economics</a>,
--   <a href="/doc/genetics/heritable/index" class="link-tag">genetics/heritable</a>,
--   <a href="/doc/psychology/writing/index" class="link-tag">psychology/writing</a>
-- </span>
tagsToLinksSpan :: [T.Text] -> Inline
tagsToLinksSpan [] = Span nullAttr []
tagsToLinksSpan [""] = Span nullAttr []
tagsToLinksSpan ts =
                       Span ("", ["link-tags"], []) (tagsToLinks ts)
-- Ditto; but since a Div is a Block element, we copy-paste a separate function:
tagsToLinksDiv :: [T.Text] -> Block
tagsToLinksDiv [] = Div nullAttr []
tagsToLinksDiv [""] = Div nullAttr []
tagsToLinksDiv ts = Div ("", ["link-tags"], []) [Para $ tagsToLinks ts]
tagsToLinks :: [T.Text] -> [Inline]
tagsToLinks [] = []
tagsToLinks ts = let tags = sort ts in
                   intersperse (Str ", ") $
                   map (\tag ->
                          Link ("", ["link-tag", "link-page", "link-annotated", "icon-not"], [("rel","tag")]) [RawInline (Format "html") $ abbreviateTag tag] ("/doc/"`T.append`tag`T.append`"/index", "Link to "`T.append`tag`T.append`" tag index")
                       ) tags

-- if a local '/doc/*' file and no tags available, try extracting a tag from the path; eg. '/doc/ai/2021-santospata.pdf' → 'ai', '/doc/ai/anime/2021-golyadkin.pdf' → 'ai/anime' etc; tags must be lowercase to map onto directory paths, but we accept uppercase variants (it's nicer to write 'economics sociology Japanese' than 'economics sociology japanese')
tag2TagsWithDefault :: String -> String -> [String]
tag2TagsWithDefault path tags = let tags' = map (trim . map toLower) $ split " " $ replace "," "" tags
                                    defTag = if ("/doc/" `isPrefixOf` path) && (not ("/doc/biology/2000-iapac-norvir"`isPrefixOf`path || "/doc/rotten.com/"`isPrefixOf`path || "/doc/statistics/order/beanmachine-multistage"`isPrefixOf`path || "/doc/www/"`isPrefixOf`path)) then tag2Default path else ""
                                in
                                  if defTag `elem` tags' || defTag == "" || defTag == "/doc" then tags' else defTag:tags'

tag2Default :: String -> String
tag2Default path = if "/doc/" `isPrefixOf` path && not ("/doc/" `isPrefixOf` path && ("/index" `isSuffixOf` path || "/index#" `isInfixOf` path)) then replace "/doc/" "" $ takeDirectory path else ""

-- de-duplicate tags: uniquefy, and remove the more general tags in favor of nested (more specific) tags. eg. ["ai", "ai/nn/transformer/gpt", "reinforcement-learning"] → ["ai/nn/transformer/gpt", "reinforcement-learning"]
uniqTags :: [String] -> [String]
uniqTags tags = nubOrd $ sort $ filter(\t -> not (any ((t++"/") `isPrefixOf`) tags)) tags

-- guess tag based on URL
pages2Tags :: String -> [String] -> [String]
pages2Tags path oldTags = url2Tags path ++ oldTags

-- We also do general-purpose heuristics on the path/URL: any page in a domain might be given a specific tag, or perhaps any URL with the string "deepmind" might be given a 'reinforcement-learning/deepmind' tag—that sort of thing.
url2Tags :: String -> [String]
url2Tags p = concatMap (\(match,tag) -> if match p then [tag] else []) urlTagDB
 where -- we allow arbitrary string predicates (so one might use regexps as well)
        urlTagDB :: [((String -> Bool), String)]
        urlTagDB = [
            (("https://publicdomainreview.org/"`isPrefixOf`),          "history/public-domain-review")
          , (("https://www.filfre.net/"`isPrefixOf`),                 "technology/digital-antiquarian")
          , (("https://abandonedfootnotes.blogspot.com"`isPrefixOf`), "sociology/abandoned-footnotes")
          , (("https://dresdencodak.com"`isPrefixOf`), "humor")
          , (("https://www.theonion.com"`isPrefixOf`), "humor")
          , (("https://tvtropes.org"`isPrefixOf`), "fiction")
          , ((\u -> anyInfix u ["evageeks.org","eva.onegeek.org", "evamonkey.com"]),  "anime/eva")
          , (("r-project.org"`isInfixOf`), "cs/r")
          , (("haskell.org"`isInfixOf`), "cs/haskell")
          ]

-- Abbreviate displayed tag names to make tag lists more readable. For some tags, like 'reinforcement-learning/*' or 'genetics/*', they might be used very heavily and densely, leading to cluttered unreadable tag lists, and discouraging use of meaningful directory names: 'reinforcement-learning/exploration, reinforcement-learning/alphago, reinforcement-learning/meta-learning, reinforcement-learning/...' would be quite difficult to read. But we also would rather not abbreviate the tag itself down to just 'rl/', as that is not machine-readable or explicit. So we can abbreviate them just for display, while rendering the tags to Inline elements.
abbreviateTag :: T.Text -> T.Text
abbreviateTag = T.pack . sedMany tagRewritesRegexes . replaceMany tagsLong2Short . replace "/doc/" "" . T.unpack
  where
        tagRewritesRegexes  :: [(String,String)]
        tagRewritesRegexes = isUniqueKeys [("^cs/", "CS/")
                             , ("^cs$", "CS")
                             , ("^cs/c$", "C")
                             , ("^cs/r$", "R")
                             , ("^ai/", "AI/")
                             , ("^ai$", "AI")
                             , ("^iq/", "IQ/")
                             , ("^iq$", "IQ")
                             , ("^iq/high$", "high IQ")
                             , ("^anime/eva$", "<em>NGE</em>")
                             , ("^gan$", "GAN")
                             , ("^psychology/", "psych/")
                             , ("^technology/", "tech/")
                             , ("^doc$", "Tags Index") -- NOTE: nothing is tagged this, so this just sets the <title> on /doc/index to something more useful than '<code>docs</code> tag'.
                             , ("^genetics/selection$", "evolution")
                             , ("^genetics/selection/natural$", "natural selection")
                             ]

listTagsAll :: IO [String]
listTagsAll = fmap (map (replace "doc/" "") . sort . filter (\f' -> not $ anyInfix f' ["personal/2011-gwern-yourmorals.org", "rotten.com", "2000-iapac-norvir", "beanmachine-multistage", "doc/www/"]) ) $ getDirFiltered (\f -> doesFileExist (f++"/index.page")) "doc/"

-- given a list of ["doc/foo/index.page"] directories, convert them to what will be the final absolute path ("/doc/foo/index"), while checking they exist (typos are easy, eg. dropping 'doc/' is common).
listTagDirectories :: [FilePath] -> IO [FilePath]
listTagDirectories direntries' = do
                       directories <- mapM getSubdirsRecursive $ map (sed "^/" "" . sed "/index$" "/" . replace "/index.page" "/")  direntries'
                       let directoriesMi = map (replace "//" "/" . (++"/index")) (concat directories)
                       directoriesVerified <- filterM (\f -> doesFileExist (f++".page")) directoriesMi
                       return $ sort $ map ("/"++) directoriesVerified

-- try to infer a long tag from a short tag, first by exact match, then by suffix, then by prefix, then by infix, then give up.
-- so eg. 'sr1' → 'SR1' → 'darknet-markets/silk-road/1', 'road/1' → 'darknet-markets/silk-road/1', 'darknet-markets/silk' → 'darknet-markets/silk-road', 'silk-road' → 'darknet-markets/silk-road'
guessTagFromShort :: [String] -> String -> String
guessTagFromShort _ "" = ""
guessTagFromShort l s = fixedPoint (f l) s
 where f m t = let allTags = nubOrd $ sort m in
                 if t `elem` allTags then t else -- exact match, no guessing required
                 case lookup t tagsShort2Long of
                   Just tl -> tl -- is an existing short/petname
                   Nothing -> let shortFallbacks =
                                    (map (\a->(a,"")) $ filter (\tag -> ("/"++ t) `isSuffixOf` tag) allTags) ++
                                    (map (\a->(a,"")) $ filter (\tag -> ("/"++ t++"/") `isInfixOf` tag) allTags) ++ -- look for matches by path segment eg. 'transformer' → 'ai/nn/transformer' (but not 'ai/nn/transformer/alphafold' or 'ai/nn/transformer/gpt')
                                    (map (\a->(a,"")) $ filter (\tag -> ("/"++t) `isSuffixOf` tag || (t++"/") `isInfixOf` tag) allTags) ++ -- look for matches by partial path segment eg. 'bias' → ' psychology/cognitive-bias/illusion-of-depth'
                                    filter (\(short,_) -> t `isSuffixOf` short) tagsShort2Long ++
                                    filter (\(short,_) -> t `isPrefixOf` short) tagsShort2Long ++
                                    filter (\(short,_) -> t `isInfixOf` short) tagsShort2Long
                              in if not (null shortFallbacks) then fst $ head shortFallbacks else
                                   let longFallbacks = filter (t `isSuffixOf`) allTags ++ filter (t `isPrefixOf`) allTags ++ filter (t `isInfixOf`) allTags in
                                     if not (null longFallbacks) then head longFallbacks else t

-- intended for use with full literal fixed-string matches, not regexps/infix/suffix/prefix matches.
tagsLong2Short, tagsShort2Long, tagsShort2LongRewrites :: [(String,String)]
tagsShort2LongRewrites = isUniqueKeys
   [("power", "statistics/power-analysis"), ("statistics/power", "statistics/power-analysis"), ("reinforcement-learning/robotics", "reinforcement-learning/robot"),
    ("reinforcement-learning/robotic", "reinforcement-learning/robot"), ("dogs", "dog"), ("dog/genetics", "genetics/heritable/dog"),
    ("dog/cloning", "genetics/cloning/dog"), ("genetics/selection/artificial/apple-breeding","genetics/selection/artificial/apple"), ("apples", "genetics/selection/artificial/apple"),
    ("T5", "ai/nn/transformer/t5"), ("link-rot", "cs/linkrot"), ("linkrot", "cs/linkrot"),
    ("ai/clip", "ai/nn/transformer/clip"), ("clip/samples", "ai/nn/transformer/clip/sample"), ("samples", "ai/nn/transformer/clip/sample"),
    ("japanese", "japan"), ("quantised", "ai/nn/sparsity/low-precision"), ("quantized", "ai/nn/sparsity/low-precision"),
    ("quantization", "ai/nn/sparsity/low-precision") , ("reduced-precision", "ai/nn/sparsity/low-precision"), ("mixed-precision", "ai/nn/sparsity/low-precision"), ("evolution", "genetics/selection/natural"),
    ("gpt-3", "ai/nn/transformer/gpt"), ("gpt3", "ai/nn/transformer/gpt"), ("gpt/nonfiction", "ai/nn/transformer/gpt/non-fiction"),
    ("red", "design/typography/rubrication"), ("self-attention", "ai/nn/transformer/attention"), ("efficient-attention", "ai/nn/transformer/attention"),
    ("ai/rnn", "ai/nn/rnn"), ("ai/retrieval", "ai/nn/retrieval"), ("mr", "genetics/heritable/correlation/mendelian-randomization"),
    ("japan/anime", "anime"), ("psychology/bird", "psychology/animal/bird"), ("psychology/birds/neuroscience", "psychology/animal/bird/neuroscience"),
    ("psychology/birds", "psychology/animal/bird"), ("dalle", "dall-e/3"), ("dall-e", "ai/nn/transformer/gpt/dall-e/3"), ("dall-e-3", "ai/nn/transformer/gpt/dall-e/3"), ("dall-1", "ai/nn/transformer/gpt/dall-e/1"), ("dall-2", "ai/nn/transformer/gpt/dall-e/2"), ("dall-3", "ai/nn/transformer/gpt/dall-e/3"),
    ("darknet-markets", "darknet-market"), ("silk-road-1", "darknet-market/silk-road/1"), ("sr1", "darknet-market/silk-road/1"),
    ("silk-road-2", "darknet-market/silk-road/2"), ("sr2", "darknet-market/silk-road/2"), ("sr/1", "darknet-market/silk-road/1"),
    ("sr/2", "darknet-market/silk-road/2"), ("sr", "darknet-market/silk-road"), ("psychology/neuroscience/bird", "psychology/animal/bird/neuroscience"),
    ("uighurs", "history/uighur"), ("ai/adversarial", "ai/nn/adversarial"), ("add", "psychiatry/adhd"),
    ("asperger", "psychiatry/autism"), ("aspergers", "psychiatry/autism"), ("personality/conscientiousness", "psychology/personality/conscientiousness"),
    ("conscientiousness", "psychology/personality/conscientiousness"), ("anorexia-nervosa", "psychiatry/anorexia"), ("anxiety-disorder", "psychiatry/anxiety"),
    ("masked-auto-encoder", "ai/nn/vae/mae"), ("masked-autoencoder", "ai/nn/vae/mae"), ("masked", "ai/nn/vae/mae"),
    ("alzheimer's", "psychiatry/alzheimers"), ("ad", "psychiatry/alzheimers"), ("alzheimers-disease", "psychiatry/alzheimers"),
    ("alzheimer", "psychiatry/alzheimers"), ("psychedelics", "psychedelic"), ("stylometric", "statistics/stylometry"),
    ("stylometrics", "statistics/stylometry"), ("dune", "fiction/science-fiction/frank-herbert"), ("herbert", "fiction/science-fiction/frank-herbert"),
    ("instruct-tuning", "instruction-tuning"), ("instruction-finetuning", "instruction-tuning"), ("psychopath", "psychology/personality/psychopathy"),
    ("sociopath", "psychology/personality/psychopathy"), ("psychopathic", "psychology/personality/psychopathy"), ("sociopathic", "psychology/personality/psychopathy"),
    ("cognitive-biases", "psychology/cognitive-bias"), ("sort", "cs/algorithm/sorting"), ("moe", "ai/scaling/mixture-of-experts"),
    ("ai/datasets", "ai/dataset"), ("ai/gan", "ai/nn/gan"), ("safety", "reinforcement-learning/safe"),
    ("ads", "economics/advertising"), ("rl/scaling", "reinforcement-learning/scaling"), ("rl/scale", "reinforcement-learning/scaling"),
    ("reinforcement-learning/scale", "reinforcement-learning/scaling"), ("rl-scaling", "reinforcement-learning/scaling"), ("scaling/rl", "reinforcement-learning/scaling"),
    ("scaling/reinforcement-learning", "reinforcement-learning/scaling"), ("reinforcement-learning/alphago", "reinforcement-learning/model/alphago"), ("evolution/human", "genetics/selection/natural/human"),
    ("rl/chess", "reinforcement-learning/chess"), ("xrisk", "existential-risk"), ("risk", "existential-risk"),
    ("human-adversarial", "ai/nn/adversarial/human"), ("adversarial-human", "ai/nn/adversarial/human"), ("mlps", "ai/nn/fully-connected"),
    ("mlp", "ai/nn/fully-connected"), ("gpt-4", "ai/nn/transformer/gpt/4"), ("gpt4", "ai/nn/transformer/gpt/4"),
    ("gp-4", "ai/nn/transformer/gpt/4"), ("gpt-5", "ai/nn/transformer/gpt/5"), ("gpt5", "ai/nn/transformer/gpt/5"),
    ("gp-5", "ai/nn/transformer/gpt/5"), ("gp5", "ai/nn/transformer/gpt/5"), ("attention/sparse", "ai/nn/transformer/attention/sparsity"),
    ("gp4-4", "ai/nn/transformer/gpt/4"), ("gp4", "ai/nn/transformer/gpt/4"), ("gpt-4/nonfiction", "ai/nn/transformer/gpt/4/nonfiction"),
    ("ai/nn/transformer/gpt/4/non-fiction", "ai/nn/transformer/gpt/4/nonfiction"), ("gpt-4/non-fiction", "ai/nn/transformer/gpt/4/nonfiction"), ("4/non", "ai/nn/transformer/gpt/4/nonfiction"),
    ("gpt-4/fiction", "ai/nn/transformer/gpt/4/fiction"), ("gpt-4/poetry", "ai/nn/transformer/gpt/4/poetry"), ("gpt-4poetry", "ai/nn/transformer/gpt/4/poetry"),
    ("gpt4/poetry", "ai/nn/transformer/gpt/4/poetry"), ("gpt-4/poem", "ai/nn/transformer/gpt/4/poetry"), ("chess", "reinforcement-learning/chess"), ("rl-chess", "reinforcement-learning/chess"), ("aimusic", "ai/music"),
    ("animal", "psychology/animal"), ("artificial", "ai"), ("code", "cs"),
    ("for", "statistics/prediction"), ("forecast", "statistics/prediction"), ("forecasting", "statistics/prediction"),
    ("genetic", "genetics"), ("graph", "design/visualization"), ("hardware" , "cs/hardware"),
    ("human" , "genetics/selection/natural/human"), ("learning", "reinforcement-learning"), ("sf", "fiction/science-fiction"),
    ("text" , "fiction/text-game"), ("psych", "psychology"), ("psych/inner-monologue", "psychology/inner-monologue"),
    ("latex", "design/typography/tex"), ("vitamind", "vitamin-d"), ("des", "design"),
    ("attention/recurrence", "attention/recurrent"), ("human-evolution", "genetics/selection/natural/human"), ("attention/algebra", "ai/nn/transformer/attention/linear-algebra"),
    ("bpe", "tokenization"), ("bpes", "tokenization"), ("silex", "psychiatry/anxiety/lavender"),
    ("lavandar", "psychiatry/anxiety/lavender"), ("decision-theory", "decision"), ("statistics/decision-theory", "statistics/decision"),
    ("language", "linguistics"), ("auction-design", "auction"), ("bilingualism", "bilingual"),
    ("rare-variants", "rare"), ("explore", "exploration"), ("allergies", "allergy"),
    ("cat-allergy", "cat/biology/allergy"), ("cat-allergies", "cat/biology/allergy"), ("antibodies", "antibody"),
    ("animal/iq", "iq/animal"), ("cellular-automata", "cellular-automaton"), ("mathematics", "math"),
    ("frank-p-ramsey", "frank-ramsey"), ("artificial-selection", "genetics/selection/artificial"), ("intrasexual-agression", "intrasexual-aggression"),
    ("javascript", "js"), ("psych/chess", "psychology/chess"), ("self-experiment", "quantified-self"),
    ("energy","psychology/energy"), ("lithium","psychiatry/lithium"), ("sequence", "sequencing"), ("quadratic-vote", "quadratic-voting"), ("bipolar/genes", "bipolar/genetics"), ("dynamic-evaliation", "dynamic-evaluation"), ("dog-cloning", "genetics/cloning/dog"), ("dog-clone", "genetics/cloning/dog"), ("dog/clone", "genetics/cloning/dog"), ("cat-drug", "cat/psychology/drug"), ("cat/drug", "cat/psychology/drug")]
tagsShort2Long = tagsShort2LongRewrites ++
  -- ^ custom tag shortcuts, to fix typos etc
  (map (\s -> (s, error s)) (isUniqueList ["a", "al", "an", "analysis", "and", "are", "as", "at", "be", "box", "done", "e", "error", "f",
                                           "fine", "free", "g", "git", "if", "in", "is", "it", "of", "on", "option", "rm", "sed", "strong",
                                           "the", "to", "tr", "up", "we"])) ++ -- hopelessly ambiguous ones which should be error (for now)
  -- attempt to infer short->long rewrites from the displayed tag names, which are long->short; but note that many of them are inherently invalid and the mapping only goes one way.
   (map (\(a,b) -> (map toLower b,a)) $ filter (\(_,fancy) -> not (anyInfix fancy [" ", "<", ">", "(",")"])) tagsLong2Short)

tagsLong2Short = isUniqueAll $ reverse [ -- priority: first one wins. so sub-directories should come before their directories if they are going to override the prefix.
          ("traffic/ab-testing", "Web A/B testing")
          , ("technology/northpaw", "Northpaw compass")
          , ("technology/self-sinking", "self-sinking disposal")
          , ("technology/google/alerts", "Google Alerts")
          , ("statistics/probability", "probability theory")
          , ("statistics/peer-review", "peer-review methodology")
          , ("statistics/causality", "causality")
          , ("statistics/bias/animal", "animal study methodology")
          , ("statistics/bias", "scientific bias")
          , ("statistics/bayes/hope-function", "the hope function")
          , ("reinforcement-learning/safe/clippy", "Clippy (AI safety)")
          , ("reinforcement-learning/imperfect-information/poker", "poker AI")
          , ("reinforcement-learning/imperfect-information/hanabi", "<em>Hanabi</em> AI")
          , ("reinforcement-learning/imperfect-information/diplomacy", "<em>Diplomacy</em> AI")
          , ("reinforcement-learning/imperfect-information", "hidden-information game")
          , ("reinforcement-learning/imitation-learning/brain-imitation-learning", "brain imitation learning")
          , ("reinforcement-learning/imitation-learning",                          "imitation learning")
          , ("reinforcement-learning/armstrong-controlproblem", "Armstrong’s RL control problem")
          , ("psychology/inner-monologue", "inner-monologue (psych)")
          , ("psychology/writing", "writing psychology")
          , ("psychology/willpower", "willpower")
          , ("psychology/vision/dream", "dreams")
          , ("psychology/vision", "seeing")
          , ("psychology/parapsychology", "parapsychology")
          , ("psychology/smell", "smelling")
          , ("psychology/smell/perfume", "perfume")
          , ("psychology/linguistics", "language")
          , ("psychology/linguistics/bilingual", "bilingualism")
          , ("psychology/collecting", "collecting psychology")
          , ("psychology/cognitive-bias/illusion-of-depth/extramission", "extramission sight theory")
          , ("psychology/cognitive-bias/illusion-of-depth", "illusion-of-depth bias")
          , ("psychiatry/meditation/lewis", "Lewis’s meditation experiment")
          , ("psychiatry/lithium", "lithium-in-water")
          , ("psychiatry/autism", "autism")
          , ("philosophy/religion", "religion")
          , ("philosophy/ontology", "ontology")
          , ("philosophy/mind", "mind")
          , ("philosophy/logic", "logic")
          , ("personal/mulberry-tree", "my mulberry-tree")
          , ("personal/2013-cicadas", "2013 cicadas")
          , ("personal/2011-gwern-yourmorals.org", "Gwern YourMorals surveys")
          , ("nootropic/caffeine", "caffeine")
          , ("math/humor", "STEM humor")
          , ("longevity/fasting", "fasting")
          , ("longevity/epigenetics", "epigenetics (aging)")
          , ("longevity/aspirin", "aspirin (aging)")
          , ("japan/history/tominaga-nakamoto", "Tominaga Nakamoto")
          , ("genetics/selection/artificial/index-selection", "index selection (breeding)")
          , ("genetics/heritable/adoption", "adoption studies")
          , ("genetics/genome-synthesis/virus-proof", "virus-proof cells")
          , ("genetics/genome-synthesis", "genome synthesis")
          , ("food/mead", "mead")
          , ("fiction/science-fiction/batman", "Batman")
          , ("fiction/humor/hardtruthsfromsoftcats.tumblr.com", "<em>Hard Truths From Soft Cats</em>")
          , ("fiction/humor/dinosaur-comics", "<em>Dinosaur Comics</em>")
          , ("existential-risk/nuclear/hofstadter", "nuclear war (Hofstadter)")
          , ("existential-risk/nuclear", "nuclear war")
          , ("economics/perpetuities", "perpetuities")
          , ("economics/copyright", "copyright (economics)")
          , ("economics/automation/metcalfes-law", "Metcalfe’s Law")
          , ("economics/automation", "automation (economics)")
          , ("economics/mechanism-design/quadratic-voting", "quadratic voting")
          , ("economics/mechanism-design/auction", "auctions")
          , ("economics/mechanism-design", "mechanism design")
          , ("design/typography/sidenote", "sidenotes (typography)")
          , ("design/typography/sentence-spacing", "sentence-spacing (typography)")
          , ("darknet-market/silk-road/1/lsd", "SR1 LSD")
          , ("cs/security", "computer security")
          , ("cs/lisp", "Lisp")
          , ("cs/hardware", "computer hardware")
          , ("cs/cryptography/nash", "John Nash (cryptography)")
          , ("cs/algorithm/sorting", "sorting")
          , ("cs/algorithm", "algorithms")
          , ("cs/computable", "computability")
          , ("cat/biology/allergy/antibody", "cat-allergen antibody")
          , ("cat/biology/allergy", "cat allergies")
          , ("cat/biology", "cat biology")
          , ("biology/booger", "boogers")
          , ("anime/hafu", "<em>hafu</em> (anime)")
          , ("anime/eva/rebuild/2/2010-crc", "<em>Rebuild 2.0</em> book")
          , ("anime/eva/rebuild/2", "<em>Rebuild 2.0</em>")
          , ("anime/eva/rebuild", "<em>Rebuild</em> (Evangelion)")
          , ("anime/eva/notenki-memoirs/blue-blazes", "<em>Blue Blazes</em>")
          , ("anime/eva/notenki-memoirs", "<em>Notenki Memoirs</em>")
          , ("anime/eva/little-boy/otaku-talk", "“Otaku Talk” roundtable")
          , ("ai/scaling/economics", "AI scaling economics")
          , ("ai/poetry", "poetry by AI")
          , ("ai/nn/transformer/gpt/calibration", "GPT calibration")
          , ("ai/nn/transformer/fiction", "Transformer fiction")
          , ("ai/nn/gan/stylegan/progan", "ProGAN")
          , ("ai/nn/gan/data-augmentation", "data-augmented GANs")
          , ("ai/nn/diffusion/discrete", "discrete diffusion model")
          , ("ai/highleyman", "Highleyman’s AI")
          , ("psychology/neuroscience/tcs", "TDCS")
          , ("traffic", "web traffic")
          , ("co2", "CO<sub>2</sub>")
          , ("zeo/short-sleeper", "short sleepers")
          , ("zeo", "sleep")
          , ("touhou", "Touhou")
          , ("bitcoin/pirateat40", "Pirateat40")
          , ("bitcoin/nashx", "Nash eXchange")
          , ("bitcoin", "Bitcoin")
          , ("borges", "J. L. Borges")
          , ("algernon", "Algernon's Law")
          , ("japan/poetry/teika",    "Fujiwara no Teika")
          , ("japan/poetry/shotetsu", "Shōtetsu")
          , ("japan/poetry/zeami",    "Zeami Motokiyo (Noh)")
          , ("japan/poetry", "Japanese poetry")
          , ("japan/art", "Japanese art")
          , ("japan/history", "Japanese history")
          , ("japan", "Japan")
          , ("long-now", "Long Now")
          , ("radiance", "<em>Radiance</em>")
          , ("psychology/cognitive-bias/stereotype-threat", "stereotype threat")
          , ("psychology/cognitive-bias/sunk-cost", "sunk cost bias")
          , ("psychology/cognitive-bias", "cognitive bias")
          , ("wikipedia", "Wikipedia")
          , ("insight-porn", "insight porn")
          , ("fiction/science-fiction", "Sci-Fi")
          , ("fiction/poetry", "poetry")
          , ("fiction/opera", "opera")
          , ("biology/portia", "<em>Portia</em> spider")
          , ("history/medici", "the Medici")
          , ("lesswrong-survey/hpmor", "<em>HP:MoR</em> surveys")
          , ("lesswrong-survey", "LW surveys")
          , ("modafinil/survey", "modafinil surveys")
          , ("crime/terrorism/rumiyah", "<em>Rumiyah</em> (ISIS)")
          , ("crime/terrorism", "terrorism")
          , ("cat/psychology/earwax", "cats & earwax")
          , ("cat/psychology", "cat psychology")
          , ("cat/genetics", "cat genetics")
          , ("cat/psychology/drug/silvervine", "silvervine (cats)")
          , ("cat/psychology/drug/catnip/survey", "catnip survey")
          , ("cat/psychology/drug/catnip", "catnip")
          , ("cat/psychology/drug/tatarian-honeysuckle", "Tatarian honeysuckle (cat)")
          , ("cat/psychology/drug/valerian", "Valerian (cat)")
          , ("fiction/science-fiction/frank-herbert", "<em>Dune</em>")
          , ("fiction/gene-wolfe/suzanne-delage", "“Suzanne Delage”")
          , ("fiction/gene-wolfe", "Gene Wolfe")
          , ("fiction/text-game", "text game")
          , ("fiction/humor", "humor")
          , ("fiction/criticism", "literary criticism")
          , ("economics/advertising", "ads")
          , ("economics/experience-curve", "experience curves")
          , ("economics/georgism", "Georgism")
          , ("genetics/microbiome", "microbiome")
          , ("genetics/heritable/correlation/mendelian-randomization", "Mendelian Randomization")
          , ("genetics/heritable/correlation", "genetic correlation")
          , ("genetics/gametogenesis", "gametogenesis")
          , ("genetics/selection/artificial", "breeding")
          , ("genetics/selection/natural/human/dysgenics", "dysgenics")
          , ("genetics/selection/natural/human", "human evolution")
          , ("genetics/heritable/emergenesis", "emergenesis")
          , ("genetics/heritable/rare", "rare mutations")
          , ("genetics/selection/artificial/apple", "apple breeding")
          , ("genetics/heritable/dog", "dog genetics")
          , ("genetics/heritable", "heritability")
          , ("genetics/cloning/dog", "dog cloning")
          , ("genetics/cloning", "cloning")
          , ("genetics/editing", "gene editing")
          , ("genetics/sequencing", "genome sequencing")
          , ("longevity/senolytic", "senolytics")
          , ("longevity/johan-bjorksten", "Johan Bjorksten (aging)")
          , ("psychology/personality/psychopathy", "psychopath")
          , ("psychiatry/meditation", "meditation")
          , ("psychiatry/depression", "MDD")
          , ("psychiatry/bipolar/autism", "BP & autism")
          , ("psychiatry/bipolar/elon-musk", "Elon Musk (BP)")
          , ("psychiatry/bipolar/sleep", "BP & sleep")
          , ("psychiatry/bipolar/lithium", "lithium (BP)")
          , ("psychiatry/bipolar/energy", "BP personality")
          , ("psychiatry/bipolar/genetics", "BP genes")
          , ("psychiatry/bipolar", "bipolar")
          , ("psychiatry/schizophrenia/rosenhan", "Rosenhan fraud")
          , ("psychiatry/schizophrenia", "SCZ")
          , ("psychiatry/anorexia", "anorexia")
          , ("psychiatry/adhd", "ADHD")
          , ("psychiatry/anxiety", "anxiety")
          , ("psychiatry/anxiety/lavender", "silexan")
          , ("psychiatry/traumatic-brain-injury", "TBI")
          , ("psychiatry/alzheimers", "Alzheimer’s")
          , ("statistics/stylometry", "stylometry")
          , ("statistics/decision/mail-delivery", "mail-delivery optimization")
          , ("statistics/decision", "decision theory")
          , ("statistics/order", "order statistics")
          , ("statistics/bayes", "Bayes")
          , ("statistics/power-analysis", "power analysis")
          , ("statistics/meta-analysis", "meta-analysis")
          , ("philosophy/ethics/ethicists", "ethicists")
          , ("statistics/order/comparison", "statistical comparison")
          , ("statistics/variance-component", "variance components")
          , ("statistics/survival-analysis", "survival analysis")
          , ("sociology/intrasexual-aggression", "intrasexual aggression")
          , ("sociology/technology", "sociology of technology")
          , ("sociology/preference-falsification", "preference falsification")
          , ("sociology/abandoned-footnotes", "<em>Abandoned Footnotes</em>")
          , ("psychology/spaced-repetition", "spaced repetition")
          , ("psychology/parapsychology/european-journal-of-parapsychology", "<em>EJP</em>")
          , ("psychology/animal/bird/neuroscience", "bird brains")
          , ("psychology/animal/bird", "bird")
          , ("psychology/animal/maze", "maze-running")
          , ("psychology/animal", "animal psych")
          , ("psychology/neuroscience", "neuroscience")
          , ("psychology/illusion-of-depth", "illusion of depth")
          , ("psychology/energy", "mental energy")
          , ("psychology/novelty", "novelty U-curve")
          , ("psychology/chess", "chess psychology")
          , ("psychology/personality/conscientiousness", "Conscientiousness")
          , ("psychology/personality", "personality")
          , ("psychology/okcupid", "OKCupid")
          , ("psychology/nature", "psych of nature")
          , ("psychology/dark-knowledge", "human ‘dark knowledge’")
          , ("psychedelic", "psychedelics")
          , ("statistics/prediction", "forecasting")
          , ("statistics/prediction/election", "election forecast")
          , ("reinforcement-learning/scaling", "RL scaling")
          , ("reinforcement-learning/exploration/active-learning", "active learning")
          , ("reinforcement-learning/exploration", "RL exploration")
          , ("reinforcement-learning/safe", "AI safety")
          , ("reinforcement-learning/robot", "robotics")
          , ("reinforcement-learning/multi-agent", "MARL")
          , ("reinforcement-learning/preference-learning", "preference learning")
          , ("reinforcement-learning/meta-learning", "meta-learning")
          , ("reinforcement-learning/deepmind", "DeepMind")
          , ("reinforcement-learning/openai", "OA")
          , ("cs/linkrot/archiving", "Internet archiving")
          , ("cs/linkrot", "linkrot (archiving)")
          , ("technology/search", "Google-fu")
          , ("technology/security", "infosec")
          , ("technology/google", "Google")
          , ("technology/digital-antiquarian", "<em>Filfre</em>")
          , ("technology/carbon-capture", "carbon capture")
          , ("technology/stevensinstituteoftechnology-satmnewsletter", "<em>SATM</em> archive")
          , ("technology", "tech")
          , ("history/public-domain-review", "<em>PD Review</em>")
          , ("history/uighur", "Uighur genocide")
          , ("reinforcement-learning/nethack", "<em>Nethack</em> AI")
          , ("reinforcement-learning/model-free/oa5", "OA5")
          , ("reinforcement-learning/model-free/alphastar", "AlphaStar")
          , ("reinforcement-learning/model/alphago", "AlphaGo")
          , ("reinforcement-learning/model/muzero", "MuZero")
          , ("reinforcement-learning/model/decision-transformer", "Decision Transformer")
          , ("reinforcement-learning/model-free", "model-free RL")
          , ("reinforcement-learning/model", "model-based RL")
          , ("darknet-market/william-pickard", "William Pickard (LSD)")
          , ("darknet-market/silk-road/2", "SR2 DNM")
          , ("darknet-market/silk-road/1", "SR1 DNM")
          , ("darknet-market/silk-road", "SR DNMs")
          , ("darknet-market/hydra", "Hydra DNM")
          , ("darknet-market/sheep-marketplace", "Sheep DNM")
          , ("darknet-market/evolution", "Evolution DNM")
          , ("darknet-market/blackmarket-reloaded", "BMR DNM")
          , ("darknet-market/atlantis", "Atlantis DNM")
          , ("darknet-market/alphabay", "AlphaBay DNM")
          , ("darknet-market/agora", "Agora DNM")
          , ("darknet-market/dnm-archive", "DNM Archives")
          , ("darknet-market", "DNM")
          , ("nootropic/quantified-self/weather", "weather & mood")
          , ("nootropic/quantified-self", "QS")
          , ("philosophy/frank-ramsey", "Frank Ramsey")
          , ("cs/end-to-end-principle", "end-to-end")
          , ("cs/python", "Python")
          , ("cs/haskell", "Haskell")
          , ("cs/js", "JS")
          , ("cs/cryptography", "crypto")
          , ("cs/css", "CSS")
          , ("cs/scheme", "Scheme Lisp")
          , ("cs/shell", "CLI")
          , ("cs/cellular-automaton", "cellular automata")
          , ("history/s-l-a-marshall", "SLAM (fraud)")
          , ("modafinil/darknet-market", "modafinil DNM")
          , ("ai/video/analysis", "video analysis")
          , ("ai/video/generation", "video generation")
          , ("ai/video", "AI video")
          , ("ai/text-style-transfer", "text style transfer")
          , ("exercise/gravitostat", "gravitostat")
          , ("longevity/semaglutide", "glutides")
          , ("longevity/tirzepatide", "tirzepatide")
          , ("philosophy/epistemology", "epistemology")
          , ("philosophy/brethren-of-purity", "Brethren of Purity")
          , ("philosophy/ethics", "ethics")
          , ("existential-risk", "x-risk")
          , ("ai/nn/sparsity/knowledge-distillation", "knowledge distillation")
          , ("ai/nn/sparsity/pruning", "NN pruning")
          , ("ai/nn/sparsity/low-precision", "reduced-precision NNs")
          , ("ai/nn/sparsity", "NN sparsity")
          , ("ai/nn/transformer/attention/hierarchical", "multi-scale Transformer")
          , ("ai/nn/transformer/attention/sparsity", "sparse Transformer")
          , ("ai/nn/transformer/attention/linear-algebra", "Transformer matrix optimization")
          , ("ai/nn/transformer/attention/compression", "compressed Transformer")
          , ("ai/nn/transformer/attention/recurrent", "recurrent Transformer")
          , ("ai/nn/transformer/t5", "T5 Transformer")
          , ("ai/nn/transformer/alphafold", "AlphaFold")
          , ("ai/nn/transformer/gpt/claude",             "Claude AI")
          , ("ai/nn/transformer/gpt/5",                  "GPT-5")
          , ("ai/nn/transformer/gpt/4/poetry",           "GPT-4 poetry")
          , ("ai/nn/transformer/gpt/4/nonfiction",       "GPT-4 nonfiction")
          , ("ai/nn/transformer/gpt/4/fiction",          "GPT-4 fiction")
          , ("ai/nn/transformer/gpt/4",                  "GPT-4")
          , ("ai/nn/transformer/gpt/3",                  "GPT-3")
          , ("ai/nn/transformer/gpt/instruction-tuning", "instruct-tuning LMs")
          , ("ai/nn/transformer/gpt/jukebox",            "Jukebox")
          , ("ai/nn/transformer/gpt/poetry",             "GPT poetry")
          , ("ai/nn/transformer/gpt/fiction",            "GPT fiction")
          , ("ai/nn/transformer/gpt/dall-e/3",           "DALL·E 3")
          , ("ai/nn/transformer/gpt/dall-e/2",           "DALL·E 2")
          , ("ai/nn/transformer/gpt/dall-e/1",           "DALL·E 1")
          , ("ai/nn/transformer/gpt/dall-e",             "DALL·E")
          , ("ai/nn/transformer/gpt/palm",               "PaLM")
          , ("ai/nn/transformer/gpt/lamda",              "LaMDA")
          , ("ai/nn/transformer/gpt/codex",              "Codex")
          , ("ai/nn/transformer/gpt/inner-monologue",    "inner monologue (AI)")
          , ("ai/nn/transformer/gpt/non-fiction",        "GPT non-fiction")
          , ("ai/nn/transformer/gpt",                    "GPT")
          , ("ai/fiction", "fiction by AI")
          , ("ai/nn/gan/stylegan", "StyleGAN")
          , ("ai/nn/gan/biggan", "BigGAN")
          , ("ai/nn/gan", "GAN")
          , ("ai/nn/diffusion/discrete ", "discrete diffusion")
          , ("ai/nn/diffusion", "diffusion model")
          , ("dual-n-back", "DNB")
          , ("vitamin-d", "Vitamin D")
          , ("design/visualization", "data visualization")
          , ("design/typography/tex", "<span class=\"logotype-tex\">T<sub>e</sub>X</span>")
          , ("design/typography/rubrication", "rubricated typography")
          , ("design/typography", "typography")
          , ("ai/nn/transformer/attention", "self-attention")
          , ("ai/nn/transformer/clip/sample", "CLIP samples")
          , ("ai/nn/transformer/clip", "CLIP")
          , ("iq/high/anne-roe", "Anne Roe's Scientists")
          , ("iq/high/fullerton", "Fullerton Longitudinal Study")
          , ("iq/high/munich", "Munich Giftedness Study")
          , ("iq/high/smpy", "SMPY")
          , ("iq/ses", "IQ & SES")
          , ("iq/animal", "animal cognition")
          , ("ai/nn/retrieval", "retrieval AI")
          , ("ai/nn/tokenization", "LM tokenization")
          , ("ai/scaling/emergence", "AI emergence")
          , ("ai/scaling/mixture-of-experts", "MoE NN")
          , ("ai/scaling", "AI scaling")
          , ("ai/nn/vae/mae", "masked auto-encoder")
          , ("ai/nn/vae", "autoencoder NN")
          , ("ai/nn/transformer", "Transformer NN")
          , ("ai/nn/fully-connected", "MLP NN")
          , ("ai/nn/dynamic-evaluation", "dynamic evaluation (NN)")
          , ("ai/nn/rnn", "RNN")
          , ("ai/nn/cnn", "CNN")
          , ("ai/nn/sampling", "NN sampling")
          , ("ai/nn", "neural net")
          , ("ai/music", "AI music")
          , ("anime/eva/little-boy", "<em>Little Boy</em>")
          , ("ai/anime/danbooru", "Danbooru AI")
          , ("ai/anime", "anime AI")
          , ("ai/nn/adversarial/human", "adversarial examples (human)")
          , ("ai/nn/adversarial", "adversarial examples (AI)")
          , ("ai/tabular", "tabular ML")
          , ("ai/dataset", "ML dataset")
          , ("reinforcement-learning/chess", "AI chess")
          , ("reinforcement-learning", "RL")
          , ("music/music-distraction", "music distraction")
          , ("newest", "newest links")
          , ("osciology", "sociology")
          ]

testTags :: IO ()
testTags = do
              tags <- listTagsAll
              let results = shortTagTestSuite tags
              unless (null results) $ error ("Tags.hs: test suite errored out with some rewrites going awry; results: " ++ show results)
              let results' = isCycleLess tagsShort2LongRewrites
              unless (null results) $ error ("Tags.hs: test suite errored out with cycles detected in `tagsShort2Long`." ++ show results')

shortTagTestSuite ::[String] -> [(String, String, String)]
shortTagTestSuite alltags = filter (\(_, realOutput, shouldbeOutput) -> realOutput /= shouldbeOutput) $
  map (\(input,output) -> (input, guessTagFromShort alltags input, output)) $ isUniqueKeys
   [("active-learning", "reinforcement-learning/exploration/active-learning")
        , ("add" , "psychiatry/adhd")
        , ("adhd" , "psychiatry/adhd")
        , ("adoption" , "genetics/heritable/adoption")
        , ("adversarial" , "ai/nn/adversarial")
        , ("advertising" , "economics/advertising")
        , ("agora" , "darknet-market/agora")
        , ("ai/adversarial" , "ai/nn/adversarial")
        , ("ai/clip" , "ai/nn/transformer/clip")
        , ("ai/gan" , "ai/nn/gan")
        , ("ai/retrieval" , "ai/nn/retrieval")
        , ("ai/rnn" , "ai/nn/rnn")
        , ("algorithm" , "cs/algorithm")
        , ("alphabay" , "darknet-market/alphabay")
        , ("alphafold" , "ai/nn/transformer/alphafold")
        , ("alphago" , "reinforcement-learning/model/alphago")
        , ("alzheimers" , "psychiatry/alzheimers")
        , ("animal" , "psychology/animal")
        , ("anorexia" , "psychiatry/anorexia")
        , ("anxiety" , "psychiatry/anxiety")
        , ("apple" , "genetics/selection/artificial/apple")
        , ("archiving" , "cs/linkrot/archiving")
        , ("artificial" , "ai")
        , ("aspirin" , "longevity/aspirin")
        , ("attention" , "ai/nn/transformer/attention")
        , ("attention/hierarchical"
          , "ai/nn/transformer/attention/hierarchical"
          )
        , ("attention/recurrent"
          , "ai/nn/transformer/attention/recurrent"
          )
        , ("autism" , "psychiatry/autism")
        , ("automation" , "economics/automation")
        , ("bayes" , "statistics/bayes")
        , ("bias" , "statistics/bias")
        , ("biggan" , "ai/nn/gan/biggan")
        , ("bipolar" , "psychiatry/bipolar")
        , ("bird" , "psychology/animal/bird")
        , ("bird/neuroscience" , "psychology/animal/bird/neuroscience")
        , ("brain-imitation-learning"
          , "reinforcement-learning/imitation-learning/brain-imitation-learning"
          )
        , ("c" , "cs/c")
        , ("caffeine" , "nootropic/caffeine")
        , ("calibration" , "ai/nn/transformer/gpt/calibration")
        , ("carbon-capture" , "technology/carbon-capture")
        , ("catnip" , "cat/psychology/drug/catnip")
        , ("causality" , "statistics/causality")
        , ("cellular-automaton" , "cs/cellular-automaton")
        , ("chess" , "reinforcement-learning/chess")
        , ("clip" , "ai/nn/transformer/clip")
        , ("clip/samples" , "ai/nn/transformer/clip/sample")
        , ("cloning" , "genetics/cloning")
        , ("cnn" , "ai/nn/cnn")
        , ("code" , "cs")
        , ("codex" , "ai/nn/transformer/gpt/codex")
        , ("cognitive-bias" , "psychology/cognitive-bias")
        , ("collecting" , "psychology/collecting")
        , ("comparison" , "statistics/order/comparison")
        , ("computable" , "cs/computable")
        , ("conscientiousness"
          , "psychology/personality/conscientiousness"
          )
        , ("copyright" , "economics/copyright")
        , ("correlation" , "genetics/heritable/correlation")
        , ("cost" , "psychology/cognitive-bias/sunk-cost")
        , ("cryptography" , "cs/cryptography")
        , ("css" , "cs/css")
        , ("dall-e" , "ai/nn/transformer/gpt/dall-e/3")
        , ("danbooru" , "ai/anime/danbooru")
        , ("dark-knowledge" , "psychology/dark-knowledge")
        , ("data" , "ai/dataset")
        , ("data-augmentation" , "ai/nn/gan/data-augmentation")
        , ("decision" , "statistics/decision")
        , ("decision-transformer"
          , "reinforcement-learning/model/decision-transformer"
          )
        , ("deepmind" , "reinforcement-learning/deepmind")
        , ("depression" , "psychiatry/depression")
        , ("des" , "design")
        , ("diff" , "ai/nn/diffusion")
        , ("diffusion" , "ai/nn/diffusion")
        , ("diplomacy"
          , "reinforcement-learning/imperfect-information/diplomacy"
          )
        , ("discrete" , "ai/nn/diffusion/discrete")
        , ("dnm-archive" , "darknet-market/dnm-archive")
        , ("do" , "dog")
        , ("dog/genetics" , "genetics/heritable/dog")
        , ("dream" , "psychology/vision/dream")
        , ("dune" , "fiction/science-fiction/frank-herbert")
        , ("editing" , "genetics/editing")
        , ("election" , "statistics/prediction/election")
        , ("emergence" , "ai/scaling/emergence")
        , ("emergenesis" , "genetics/heritable/emergenesis")
        , ("end-to-end" , "cs/end-to-end-principle")
        , ("end-to-end-principle" , "cs/end-to-end-principle")
        , ("energy" , "psychology/energy")
        , ("epigenetic" , "longevity/epigenetics")
        , ("epigenetics" , "longevity/epigenetics")
        , ("epistemology" , "philosophy/epistemology")
        , ("ethicists" , "philosophy/ethics/ethicists")
        , ("ethics" , "philosophy/ethics")
        , ("eva" , "anime/eva")
        , ("evolution" , "genetics/selection/natural")
        , ("evolution/human" , "genetics/selection/natural/human")
        , ("experience-curve" , "economics/experience-curve")
        , ("exploration" , "reinforcement-learning/exploration")
        , ("for" , "statistics/prediction")
        , ("frank-herbert" , "fiction/science-fiction/frank-herbert")
        , ("full" , "ai/nn/fully-connected")
        , ("fully-connected" , "ai/nn/fully-connected")
        , ("gametogenesis" , "genetics/gametogenesis")
        , ("gan" , "ai/nn/gan")
        , ("generation" , "ai/video/generation")
        , ("genetic" , "genetics")
        , ("gene-wolfe" , "fiction/gene-wolfe")
        , ("genome-synthesis" , "genetics/genome-synthesis")
        , ("georgism" , "economics/georgism")
        , ("google" , "technology/google")
        , ("gp-4" , "ai/nn/transformer/gpt/4")
        , ("gp4" , "ai/nn/transformer/gpt/4")
        , ("gpt" , "ai/nn/transformer/gpt")
        , ("gpt-3" , "ai/nn/transformer/gpt")
        , ("gpt-4" , "ai/nn/transformer/gpt/4")
        , ("gpt4" , "ai/nn/transformer/gpt/4")
        , ("gpt-4/fiction" , "ai/nn/transformer/gpt/4/fiction")
        , ("gpt-4/non" , "ai/nn/transformer/gpt/4/nonfiction")
        , ("gpt/4/non" , "ai/nn/transformer/gpt/4/nonfiction")
        , ("gpt-4/nonfiction" , "ai/nn/transformer/gpt/4/nonfiction")
        , ("gpt/4/non-fiction" , "ai/nn/transformer/gpt/4/nonfiction")
        , ("gpt/4/nonfiction" , "ai/nn/transformer/gpt/4/nonfiction")
        , ("gpt-4/poetry" , "ai/nn/transformer/gpt/4/poetry")
        , ("gpt/4/poetry" , "ai/nn/transformer/gpt/4/poetry")
        , ("gpt4/poetry" , "ai/nn/transformer/gpt/4/poetry")
        , ("gpt-4poetry" , "ai/nn/transformer/gpt/4/poetry")
        , ("gpt/codex" , "ai/nn/transformer/gpt/codex")
        , ("gpt/fiction" , "ai/nn/transformer/gpt/fiction")
        , ("gpt/inner-monologue"
          , "ai/nn/transformer/gpt/inner-monologue"
          )
        , ("gpt/non" , "ai/nn/transformer/gpt/non-fiction")
        , ("gpt/non-fiction" , "ai/nn/transformer/gpt/non-fiction")
        , ("gpt/nonfiction" , "ai/nn/transformer/gpt/non-fiction")
        , ("gpt/poetry" , "ai/nn/transformer/gpt/poetry")
        , ("graph" , "design/visualization")
        , ("hanabi"
          , "reinforcement-learning/imperfect-information/hanabi"
          )
        , ("hardware" , "cs/hardware")
        , ("haskell" , "cs/haskell")
        , ("heritable" , "genetics/heritable")
        , ("heritable/correlation" , "genetics/heritable/correlation")
        , ("hierarchical" , "ai/nn/transformer/attention/hierarchical")
        , ("highleyman" , "ai/highleyman")
        , ("human" , "genetics/selection/natural/human")
        , ("humor" , "fiction/humor")
        , ("illusion-of-depth"
          , "psychology/cognitive-bias/illusion-of-depth"
          )
        , ("imperfect-information"
          , "reinforcement-learning/imperfect-information"
          )
        , ("inner-monologue" , "ai/nn/transformer/gpt/inner-monologue")
        , ("instruction-tuning"
          , "ai/nn/transformer/gpt/instruction-tuning"
          )
        , ("japan/anime" , "anime")
        , ("japanese" , "japan")
        , ("jukebox" , "ai/nn/transformer/gpt/jukebox")
        , ("knowledge-distillation"
          , "ai/nn/sparsity/knowledge-distillation"
          )
        , ("lamda" , "ai/nn/transformer/gpt/lamda")
        , ("learning"
          , "reinforcement-learning"
          )
        , ("less" , "lesswrong-survey")
        , ("link-rot" , "cs/linkrot")
        , ("linkrot" , "cs/linkrot")
        , ("linkrot/archiving" , "cs/linkrot/archiving")
        , ("lisp" , "cs/lisp")
        , ("lithium" , "psychiatry/lithium")
        , ("logic" , "philosophy/logic")
        , ("low-precision" , "ai/nn/sparsity/low-precision")
        , ("mae" , "ai/nn/vae/mae")
        , ("meditation" , "psychiatry/meditation")
        , ("mendelian-randomization"
          , "genetics/heritable/correlation/mendelian-randomization"
          )
        , ("meta-analysis" , "statistics/meta-analysis")
        , ("meta-learning" , "reinforcement-learning/meta-learning")
        , ("microbiome" , "genetics/microbiome")
        , ("mind" , "philosophy/mind")
        , ("mixture" , "ai/scaling/mixture-of-experts")
        , ("mixture-of-experts" , "ai/scaling/mixture-of-experts")
        , ("model" , "reinforcement-learning/model")
        , ("model-free" , "reinforcement-learning/model-free")
        , ("moe" , "ai/scaling/mixture-of-experts")
        , ("multi-agent" , "reinforcement-learning/multi-agent")
        , ("music-distraction" , "music/music-distraction")
        , ("muzero" , "reinforcement-learning/model/muzero")
        , ("natural" , "genetics/selection/natural")
        , ("nature" , "psychology/nature")
        , ("n-back" , "dual-n-back")
        , ("nethack" , "reinforcement-learning/nethack")
        , ("neuroscience" , "psychology/neuroscience")
        , ("nn" , "ai/nn")
        , ("non-fiction" , "ai/nn/transformer/gpt/non-fiction")
        , ("novelty" , "psychology/novelty")
        , ("oa5" , "reinforcement-learning/model-free/oa5")
        , ("ontology" , "philosophy/ontology")
        , ("opera" , "fiction/opera")
        , ("order" , "statistics/order")
        , ("palm" , "ai/nn/transformer/gpt/palm")
        , ("peer-review" , "statistics/peer-review")
        , ("perpetuities" , "economics/perpetuities")
        , ("personality" , "psychology/personality")
        , ("personality/conscientiousness"
          , "psychology/personality/conscientiousness"
          )
        , ("poetry" , "fiction/poetry")
        , ("portia" , "biology/portia")
        , ("power" , "statistics/power-analysis")
        , ("power-analysis" , "statistics/power-analysis")
        , ("prediction" , "statistics/prediction")
        , ("prediction/election" , "statistics/prediction/election")
        , ("preference-falsification"
          , "sociology/preference-falsification"
          )
        , ("preference-learning"
          , "reinforcement-learning/preference-learning"
          )
        , ("probability" , "statistics/probability")
        , ("pruning" , "ai/nn/sparsity/pruning")
        , ("psycholog" , "psychology/animal/bird")
        , ("psychology/bird" , "psychology/animal/bird")
        , ("psychopath" , "psychology/personality/psychopathy")
        , ("public-domain-review" , "history/public-domain-review")
        , ("python" , "cs/python")
        , ("quantified-self" , "nootropic/quantified-self")
        , ("r" , "cs/r")
        , ("red" , "design/typography/rubrication")
        , ("reduced-precision" , "ai/nn/sparsity/low-precision")
        , ("reinforcement-learning/alphago"
          , "reinforcement-learning/model/alphago"
          )
        , ("religion" , "philosophy/religion")
        , ("repetition" , "psychology/spaced-repetition")
        , ("retrieval" , "ai/nn/retrieval")
        , ("review" , "history/public-domain-review")
        , ("risk" , "existential-risk")
        , ("rl-scaling" , "reinforcement-learning/scaling")
        , ("rl/scaling" , "reinforcement-learning/scaling")
        , ("rnn" , "ai/nn/rnn")
        , ("robot" , "reinforcement-learning/robot")
        , ("robotics" , "reinforcement-learning/robot")
        , ("rosenhan" , "psychiatry/schizophrenia/rosenhan")
        , ("rubrication" , "design/typography/rubrication")
        , ("rumiyah" , "crime/terrorism/rumiyah")
        , ("safe" , "reinforcement-learning/safe")
        , ("samples" , "ai/nn/transformer/clip/sample")
        , ("sampling" , "ai/nn/sampling")
        , ("scaling" , "ai/scaling")
        , ("scaling/economics" , "ai/scaling/economics")
        , ("scaling/hardware" , "ai/scaling/hardware")
        , ("schizophrenia" , "psychiatry/schizophrenia")
        , ("science-fiction" , "fiction/science-fiction")
        , ("security" , "cs/security")
        , ("selection" , "genetics/selection")
        , ("selection/artificial" , "genetics/selection/artificial")
        , ("selection/natural" , "genetics/selection/natural")
        , ("self-sinking" , "technology/self-sinking")
        , ("semaglutide" , "longevity/semaglutide")
        , ("sentence-spacing" , "design/typography/sentence-spacing")
        , ("sequencing" , "genetics/sequencing")
        , ("sf" , "fiction/science-fiction")
        , ("short-sleeper" , "zeo/short-sleeper")
        , ("silk-road" , "darknet-market/silk-road")
        , ("silk-road/1" , "darknet-market/silk-road/1")
        , ("silk-road/2" , "darknet-market/silk-road/2")
        , ("sleep" , "zeo")
        , ("smell" , "psychology/smell")
        , ("sort" , "cs/algorithm/sorting")
        , ("sorting" , "cs/algorithm/sorting")
        , ("spaced-repetition" , "psychology/spaced-repetition")
        , ("sparsity" , "ai/nn/sparsity")
        , ("sparsity/pruning" , "ai/nn/sparsity/pruning")
        , ("stereotype-threat"
          , "psychology/cognitive-bias/stereotype-threat"
          )
        , ("stylegan" , "ai/nn/gan/stylegan")
        , ("stylometrics" , "statistics/stylometry")
        , ("stylometry" , "statistics/stylometry")
        , ("sunk-cost" , "psychology/cognitive-bias/sunk-cost")
        , ("survival" , "statistics/survival-analysis")
        , ("survival-analysis" , "statistics/survival-analysis")
        , ("t5" , "ai/nn/transformer/t5")
        , ("tabular" , "ai/tabular")
        , ("tbi" , "psychiatry/traumatic-brain-injury")
        , ("tcs" , "psychology/neuroscience/tcs")
        , ("teika" , "japan/poetry/teika")
        , ("terrorism" , "crime/terrorism")
        , ("text" , "fiction/text-game")
        , ("text-game" , "fiction/text-game")
        , ("text-style-transfer" , "ai/text-style-transfer")
        , ("tirzepatide" , "longevity/tirzepatide")
        , ("tokenization" , "ai/nn/tokenization")
        , ("traction" , "music/music-distraction")
        , ("transformer" , "ai/nn/transformer")
        , ("transformer/attention" , "ai/nn/transformer/attention")
        , ("transformer/gpt" , "ai/nn/transformer/gpt")
        , ("traumatic-brain-injury"
          , "psychiatry/traumatic-brain-injury"
          )
        , ("typography" , "design/typography")
        , ("uighur" , "history/uighur")
        , ("vae" , "ai/nn/vae")
        , ("video/analysis" , "ai/video/analysis")
        , ("video/generatio" , "ai/video/generation")
        , ("video/generation" , "ai/video/generation")
        , ("vision" , "psychology/vision")
        , ("visual" , "design/visualization")
        , ("visualization" , "design/visualization")
        , ("willpower" , "psychology/willpower")
        , ("writing" , "psychology/writing")
        , ("psych/inner-monologue", "psychology/inner-monologue")
        ]
