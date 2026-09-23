{-# LANGUAGE OverloadedStrings #-}

-- | JSON encoding for the wasm foreign interface — both the batch shape
-- ('encodeWorld', the whole 'World' at once, 'Historian.Rules.generate's
-- own boundary) and the incremental one ('encodeStepResult'\/
-- 'encodeQueryResult', a single step's delta or a single entity's
-- dossier, 'Historian.Engine.stepAutonomous'\/'Historian.Engine.
-- queryEntity's own boundary — see @.claude/docs/DESIGN.md@ Decision 7 and its
-- stateful-handle follow-up).
--
-- Deliberately hand-written rather than a derived instance on 'World'
-- itself: 'World' also carries the RNG state and per-culture Markov
-- chains, which are generator-internal bookkeeping with no business
-- leaving Haskell. Only entities, events, and facts — the queryable
-- output — cross the boundary.
module Historian.Json (encodeWorld, encodeStepResult, encodeQueryResult, encodeRulesFor, encodeNextSlotFromPool, encodeTuning, decodeTuningOverride) where

import Data.Aeson (Value (..), object, (.:?), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson (Parser, parseMaybe)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Historian.Engine (EntityDossier (..), PoolAmbiguity (..), RuleSpec (..), Slot (..))
import Historian.Types
import Historian.World (dateOf, nameIn, propertyOf)

encodeWorld :: World -> BSL.ByteString
encodeWorld w =
  Aeson.encode $
    object
      [ "entities" .= map (entityJson w) (M.elems (wEntities w))
      , "events" .= map (eventJson w) (M.elems (wEvents w))
      , -- Oldest first, matching the order 'Historian.Render.chronicle' and
        -- 'Historian.Render.dossier' already read the log in.
        "facts" .= map (factJson w) (reverse (wFacts w))
      ]

-- | One 'Historian.Engine.stepAutonomous' call's delta between the 'World'
-- before and after — not the whole world, per the stateful-handle design
-- (@.claude/docs/DESIGN.md@ Decision 7's follow-up): just what a single step
-- actually added. 'wEntities'\/'wEvents' are keyed maps, so
-- 'M.difference' finds exactly the new ones; 'wFacts' is a newest-first
-- list that 'Historian.World.record' only ever prepends to, so the new
-- facts are exactly its first @n@ elements, @n@ being however many
-- entries longer it got.
encodeStepResult :: World -> World -> BSL.ByteString
encodeStepResult before after =
  Aeson.encode $
    object
      [ "fired" .= not (M.null newEvents)
      , "newEntities" .= map (entityJson after) (M.elems newEntities)
      , "newEvents" .= map (eventJson after) (M.elems newEvents)
      , "newFacts" .= map (factJson after) newFacts
      ]
  where
    newEntities = M.difference (wEntities after) (wEntities before)
    newEvents = M.difference (wEvents after) (wEvents before)
    newFacts = take (length (wFacts after) - length (wFacts before)) (wFacts after)

-- | A single entity's dossier ('Historian.Engine.queryEntity's own
-- result), or JSON @null@ for an id that doesn't resolve — the query half
-- of the stateful-handle boundary, alongside 'encodeStepResult'.
encodeQueryResult :: World -> Maybe EntityDossier -> BSL.ByteString
encodeQueryResult _ Nothing = Aeson.encode Null
encodeQueryResult w (Just d) = Aeson.encode (dossierJson w d)

dossierJson :: World -> EntityDossier -> Value
dossierJson w d =
  object
    [ "id" .= unEntityId (edId d)
    , "kind" .= kindText (edKind d)
    , "name" .= edName d
    , "culture" .= unCulture (edCulture d)
    , "born" .= unEpoch (edBorn d)
    , "bornDate" .= dateOf w (edBorn d)
    , "facts" .= map (factJson w) (edFacts d)
    , "satisfiesSlotOf" .= edSatisfiesSlotOf d
    , "voice" .= fmap (voiceRegisterText . voiceRegister) (edVoice d)
    ]

-- | 'Historian.Engine.rulesFor's own wire shape — every 'RuleSpec' that
-- could use at least one entity from the given pool, ranked by
-- 'Historian.Engine.bestPoolUse'. Never used offline; a host with an
-- entity selection in hand calls this to know which rules are even worth
-- offering.
encodeRulesFor :: [(RuleSpec, Int)] -> BSL.ByteString
encodeRulesFor ranked =
  Aeson.encode
    [object ["rule" .= rsName rs, "score" .= n] | (rs, n) <- ranked]

-- | 'Historian.Engine.nextSlotFromPool's own wire shape. Three distinct
-- outcomes, matched to three JSON shapes rather than one loosely-typed
-- object, so a host can dispatch without probing which fields are
-- present: an ambiguous pool (@"ambiguous"@, with every competing
-- binding shape as parallel-array entity ids\/nulls, so a host can show
-- the actual choice rather than just a count); a rule the pool already
-- fully resolves (@"done"@); or the next open slot with its real
-- candidates (@"slot"@, reusing 'dossierJson' — the exact 'EntityDossier'
-- shape 'encodeQueryResult' already exposes, not a second parallel one).
encodeNextSlotFromPool :: World -> Either PoolAmbiguity (Maybe (Int, Slot, [EntityDossier])) -> BSL.ByteString
encodeNextSlotFromPool w = \case
  Left (PoolAmbiguity shapes) ->
    Aeson.encode $
      object
        [ "status" .= ("ambiguous" :: Text)
        , "shapes" .= map (map (fmap unEntityId)) shapes
        ]
  Right Nothing -> Aeson.encode (object ["status" .= ("done" :: Text)])
  Right (Just (i, slot, candidates)) ->
    Aeson.encode $
      object
        [ "status" .= ("slot" :: Text)
        , "slotIndex" .= i
        , "slotKind" .= kindText (slotKind slot)
        , "candidates" .= map (dossierJson w) candidates
        ]

entityJson :: World -> Entity -> Value
entityJson w e =
  object
    [ "id" .= unEntityId (entId e)
    , "kind" .= kindText (entKind e)
    , "name" .= nameIn w (entId e)
    , "culture" .= unCulture (entCulture e)
    , "born" .= unEpoch (entBorn e)
    , "bornDate" .= dateOf w (entBorn e)
    , -- The concept's name, not a bare id: a relic's nature should be
      -- readable straight off the wire format, not need a second lookup.
      "property" .= fmap (nameIn w) (propertyOf w (entId e))
    , -- 'Nothing' for every 'Kind' but 'Society' (see 'entVoice'). Additive
      -- field — needed by work item 24 Tier 3's register-flavored Axis A
      -- content (@.claude/docs/plans/24-ttrpg-cult-export.md@ §5): a
      -- frontend can't pick a "Grim cult reads different from a Fervent
      -- one" table variant without knowing which register a queried
      -- society actually has. Nothing else has needed 'entVoice'
      -- client-side before this.
      "voice" .= fmap (voiceRegisterText . voiceRegister) (entVoice e)
    ]

kindText :: Kind -> Text
kindText = \case
  Society -> "Society"
  Person -> "Person"
  Site -> "Site"
  Item -> "Item"
  Concept -> "Concept"

voiceRegisterText :: VoiceRegister -> Text
voiceRegisterText = \case
  Plain -> "Plain"
  Fervent -> "Fervent"
  Grim -> "Grim"

-- | Work item 25: 'text'\/'narratedText' now carry 'mentionMarker'
-- (U+E000, documented in @.claude/docs/INTERFACE.md@) wherever an entity
-- was named, instead of the resolved name inline — 'textMentions'\/
-- 'narratedTextMentions' are each marker's own word, in order, so a host
-- never has to re-scan an idiosyncratically-mangled reading to find them
-- again. See Decision 47.
eventJson :: World -> Event -> Value
eventJson w ev =
  object
    [ "id" .= unEventId (evId ev)
    , "epoch" .= unEpoch (evEpoch ev)
    , "date" .= dateOf w (evEpoch ev)
    , "kind" .= evKind ev
    , -- Unchanged field name and meaning: always the neutral reading,
      -- never touched by voice or idiosyncrasies — the permanent "generic
      -- log" text kept for the wasm FFI. Its content now carries markers
      -- like every other 'AText', for the same reason: a consistent shape
      -- regardless of which reading a host displays.
      "text" .= atText (evNeutralText ev)
    , "textMentions" .= map mentionJson (atMentions (evNeutralText ev))
    , "narratedText" .= atText (evNarratedText ev)
    , "narratedTextMentions" .= map mentionJson (atMentions (evNarratedText ev))
    , "narrator" .= fmap unEntityId (evNarrator ev)
    ]

mentionJson :: Mention -> Value
mentionJson m = object ["entity" .= unEntityId (mnEntity m), "text" .= mnText m]

factJson :: World -> Fact -> Value
factJson w f =
  object
    [ "subject" .= unEntityId (factSubject f)
    , "predicate" .= predicateText (factPred f)
    , "object" .= fmap referentJson (factObject f)
    , "epoch" .= unEpoch (factEpoch f)
    , "date" .= dateOf w (factEpoch f)
    , "source" .= unEventId (factSource f)
    , "attestedBy" .= fmap unEntityId (factAttestedBy f)
    , "significance" .= significanceOf (factPred f)
    ]

-- | How narratively load-bearing a fact tends to be, on a fixed 1-5 scale
-- — a pure function of 'Predicate' alone, additive to the existing wire
-- format (work item 24, Tier 1: @.claude/docs/plans/24-ttrpg-cult-export.md@
-- §2). 'historian_query's dossier already returns every fact, oldest
-- first, with no sense of which ones matter for a table-ready summary;
-- scoring which predicates are rare or terminal is domain knowledge only
-- this generator has (a fact about its own rule weights), so it stays
-- here rather than asking a frontend to guess. A frontend sorts\/filters
-- on this field itself to curate "major beats" — nothing here decides
-- that, same "score, don't curate" split 'dossierJson' already draws for
-- 'edSatisfiesSlotOf'. Hand-authored like 'predicateText', not derived
-- from an actual rarity count across generated worlds — Tier 3's own
-- fallback-chain logic (plan §5 Axis B) already leans on real per-cult
-- facts for texture, so this only needs to be a reasonable ranking, not
-- an exact one. 5 = pivotal/rare (a society or relic's permanent end, a
-- death, a schism, a declared heretic); 1 = routine bookkeeping a dossier
-- accumulates constantly (bare membership, a concept's intrinsic link).
significanceOf :: Predicate -> Int
significanceOf = \case
  Founded -> 5
  SplitFrom -> 5
  Terminated -> 5
  MergedInto -> 5
  Slain -> 5
  BattledAt -> 4
  Heretic -> 4
  Sanctified -> 4
  Fulfilled -> 4
  Prophesied -> 3
  Revives -> 3
  TrainedBy -> 2
  Leads -> 2
  Named -> 2
  Grievance -> 2
  Reconciled -> 2
  Rivalry -> 2
  Venerates -> 2
  Shuns -> 2
  Disavows -> 1
  Disputes -> 1
  LeaderOf -> 1
  Embodies -> 1

-- | Spelled out explicitly, not derived from 'Show': this is a wire format
-- other programs will parse, so a future constructor rename shouldn't
-- silently change it the way relying on 'Predicate's derived 'Show' would.
predicateText :: Predicate -> Text
predicateText = \case
  Founded -> "Founded"
  LeaderOf -> "LeaderOf"
  SplitFrom -> "SplitFrom"
  Grievance -> "Grievance"
  Slain -> "Slain"
  BattledAt -> "BattledAt"
  Disputes -> "Disputes"
  Reconciled -> "Reconciled"
  Sanctified -> "Sanctified"
  Venerates -> "Venerates"
  Shuns -> "Shuns"
  Disavows -> "Disavows"
  Heretic -> "Heretic"
  MergedInto -> "MergedInto"
  Revives -> "Revives"
  Prophesied -> "Prophesied"
  Fulfilled -> "Fulfilled"
  Embodies -> "Embodies"
  Named -> "Named"
  Leads -> "Leads"
  Rivalry -> "Rivalry"
  Terminated -> "Terminated"
  TrainedBy -> "TrainedBy"

referentJson :: Referent -> Value
referentJson = \case
  ROf e -> object ["entity" .= unEntityId e]
  REvent e -> object ["event" .= unEventId e]
  ROmen e mp -> object ["entity" .= unEntityId e, "omen" .= fmap predicateText mp]
  RName t -> object ["name" .= t]

-- | Every 'Tuning' field, spelled out by name rather than derived — the
-- wire format a wasm host reads (to build a "here's what's tunable" UI
-- from) and writes (see 'decodeTuningOverride'). An @(existing, generate,
-- omit)@ weight triple crosses as a 3-element array in that same order,
-- via 'tripleJson'\/'parseTriple' below rather than aeson's own generic
-- tuple instance — explicit, not implicit, the same reasoning
-- 'predicateText' already documents for why this module hand-writes
-- every shape it exposes.
encodeTuning :: Tuning -> BSL.ByteString
encodeTuning t =
  Aeson.encode $
    object
      [ "tnBackfillWeights" .= tripleJson (tnBackfillWeights t)
      , "tnBackfillMaxDepth" .= tnBackfillMaxDepth t
      , "tnBackdatedSaintWeights" .= tripleJson (tnBackdatedSaintWeights t)
      , "tnNarratorAttested" .= tnNarratorAttested t
      , "tnNarratorOtherShare" .= tnNarratorOtherShare t
      , "tnAllCapsChance" .= tnAllCapsChance t
      , "tnHailChance" .= tnHailChance t
      , "tnMeanderChance" .= tnMeanderChance t
      , "tnOmitChance" .= tnOmitChance t
      , "tnThemedItemNameChance" .= tnThemedItemNameChance t
      , "tnMundaneMiracleChance" .= tnMundaneMiracleChance t
      , "tnCultureDriftChance" .= tnCultureDriftChance t
      , "tnSameCultureBoost" .= tnSameCultureBoost t
      , "tnFoundingPurposeChance" .= tnFoundingPurposeChance t
      , "tnRuinsNameChance" .= tnRuinsNameChance t
      , "tnSiteOriginChance" .= tnSiteOriginChance t
      , "tnApprenticeshipChance" .= tnApprenticeshipChance t
      , "tnApprenticeBoost" .= tnApprenticeBoost t
      , "tnLineageBoost" .= tnLineageBoost t
      ]

tripleJson :: (Int, Int, Int) -> Value
tripleJson (a, b, c) = Aeson.toJSON ([a, b, c] :: [Int])

parseTriple :: Value -> Aeson.Parser (Int, Int, Int)
parseTriple v = do
  xs <- Aeson.parseJSON v :: Aeson.Parser [Int]
  case xs of
    [a, b, c] -> pure (a, b, c)
    _ -> fail "expected a 3-element [existing, generate, omit] array"

-- | Decodes a *partial* 'Tuning' override — any field the JSON object
-- omits keeps 'defaultTuning's own value, so a frontend offering only a
-- handful of sliders doesn't need to round-trip every field it isn't
-- customizing. 'Nothing' for malformed JSON (not an object, or a field
-- present with the wrong shape) rather than silently falling back to
-- defaults for a caller's own typo — the wasm boundary's own
-- 'historian_new_tuned' treats that the same way 'historian_next_slot'
-- already treats an unrecognised rule name: a safe, named fallback
-- shape, not a trap.
decodeTuningOverride :: BSL.ByteString -> Maybe Tuning
decodeTuningOverride bs = Aeson.decode bs >>= Aeson.parseMaybe parseTuning
  where
    parseTuning = Aeson.withObject "Tuning" $ \o -> do
      let base = defaultTuning
          optTriple key d = o .:? key >>= maybe (pure d) parseTriple
          optInt key d = o .:? key Aeson..!= d
      Tuning
        <$> optTriple "tnBackfillWeights" (tnBackfillWeights base)
        <*> optInt "tnBackfillMaxDepth" (tnBackfillMaxDepth base)
        <*> optTriple "tnBackdatedSaintWeights" (tnBackdatedSaintWeights base)
        <*> optInt "tnNarratorAttested" (tnNarratorAttested base)
        <*> optInt "tnNarratorOtherShare" (tnNarratorOtherShare base)
        <*> optInt "tnAllCapsChance" (tnAllCapsChance base)
        <*> optInt "tnHailChance" (tnHailChance base)
        <*> optInt "tnMeanderChance" (tnMeanderChance base)
        <*> optInt "tnOmitChance" (tnOmitChance base)
        <*> optInt "tnThemedItemNameChance" (tnThemedItemNameChance base)
        <*> optInt "tnMundaneMiracleChance" (tnMundaneMiracleChance base)
        <*> optInt "tnCultureDriftChance" (tnCultureDriftChance base)
        <*> optInt "tnSameCultureBoost" (tnSameCultureBoost base)
        <*> optInt "tnFoundingPurposeChance" (tnFoundingPurposeChance base)
        <*> optInt "tnRuinsNameChance" (tnRuinsNameChance base)
        <*> optInt "tnSiteOriginChance" (tnSiteOriginChance base)
        <*> optInt "tnApprenticeshipChance" (tnApprenticeshipChance base)
        <*> optInt "tnApprenticeBoost" (tnApprenticeBoost base)
        <*> optInt "tnLineageBoost" (tnLineageBoost base)
