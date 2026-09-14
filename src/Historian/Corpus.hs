{-# LANGUAGE OverloadedStrings #-}

-- | Training data. Swap these lists to reskin the whole generator.
module Historian.Corpus where

import Data.Text (Text)
import Historian.Types (Culture (..), Kind (..))

vaurethine :: Culture
vaurethine = Culture "Vaurethine"

hollowtongue :: Culture
hollowtongue = Culture "Hollowtongue"

allCultures :: [Culture]
allCultures = [vaurethine, hollowtongue]

-- | Total by construction: an unrecognised culture falls back rather than
-- crashing, which matters once cultures are minted at runtime.
corpusFor :: Culture -> [String]
corpusFor (Culture "Hollowtongue") = hollowWords
corpusFor _ = vaureWords

vaureWords :: [String]
vaureWords =
  [ "vaurethine", "ossilane", "thessomar", "viremundis", "calcedon"
  , "aurelith", "sarravent", "mendicorum", "tenebris", "solvantine"
  , "quirethis", "palladine", "umbracine", "cinerion", "velluthar"
  , "ostravane", "ferrasine", "lucivane", "arcanthos", "ravellion"
  , "silaurent", "thaumine", "obscurine", "veridane", "malacor"
  , "sanctorine", "ignivault", "corvassine", "ambroselle", "nectarion"
  ]

hollowWords :: [String]
hollowWords =
  [ "grendleth", "harrowkin", "orbeck", "thrangar", "kelduth"
  , "morwick", "dregmar", "valthok", "skerrand", "bruthan"
  , "hagvold", "ormsgate", "tarrowen", "gethrune", "drossick"
  , "kaldbrek", "vennrath", "wormgeld", "stakhold", "thelgrim"
  , "morgath", "ruskvane", "ohtberd", "wexholt", "gnarlend"
  , "brimmoth", "haldreck", "stennvar", "ulgareth", "fennwick"
  ]

societyEpithets :: [Text]
societyEpithets =
  [ "Sundered", "Ashen", "Veiled", "Ninefold", "Weeping"
  , "Silent", "Gilded", "Hollow", "Thrice-Bound", "Unwritten"
  ]

societyNouns :: [Text]
societyNouns =
  [ "Concordance", "Choir", "Assembly", "Covenant", "Lantern"
  , "Vigil", "Cenacle", "Fraternity", "Congregation", "Order"
  ]

siteNouns :: [Text]
siteNouns =
  [ "Column", "Ossuary", "Bridge", "Gate", "Wellhead"
  , "Terrace", "Reliquary", "Barrow", "Cistern", "Stair"
  ]

bynames :: [Text]
bynames =
  [ "the Younger", "the Unmarred", "the Twice-Buried", "of the Low Choir"
  , "the Recanter", "the Blind", "the Unshriven", "Handless"
  ]

-- | Calendar month names are "{adjective} {noun}", with an optional
-- trailing ", {epithet}" — "Dancing Butcher" or "Eastern Child, Turning".
-- Deliberately a different register from the society/site word lists
-- above: a calendar should feel folk and seasonal, not institutional.
monthAdjectives :: [Text]
monthAdjectives =
  [ "Dancing", "Eastern", "Weeping", "Drowned", "Hollow"
  , "Bleeding", "Silent", "Gilded", "Withered", "Waking"
  , "Fasting", "Nameless"
  ]

monthNouns :: [Text]
monthNouns =
  [ "Butcher", "Child", "Harvest", "Wolf", "Ember"
  , "Tide", "Bell", "Thorn", "Widow", "Lantern"
  , "Serpent", "Ash"
  ]

monthEpithets :: [Text]
monthEpithets =
  [ "Turning", "Waning", "Ascendant", "Reversed"
  , "Unbound", "Drowning", "Silent"
  ]

-- | Names for the single named era a world's calendar reckons from —
-- "Year 5 After the Sundering", "Year -3 of the Long Silence". One era per
-- world, chosen once; see 'Historian.World.calendarParams'.
eraNames :: [Text]
eraNames =
  [ "the Sundering", "the Reckoning", "the Long Silence", "the First Betrayal"
  , "the Drowning", "the Unmaking", "the Ashen Peace", "the Turning"
  , "the Hollow Accord", "the Last Kindling"
  ]

-- | What a prophecy foretells, keyed by the kind of thing it's about.
-- Deliberately never comes true or false on its own — see
-- 'Historian.Rules.ruleProphesy' — so these read as doom-saying in general
-- terms, not as a specific claim some later rule could ever be checked
-- against.
prophecyFramings :: Kind -> [Text]
prophecyFramings Society =
  [ "will fall to ruin within a generation"
  , "will be torn apart from within"
  , "will forget the name of its own founder"
  , "will be the death of everything it claims to protect"
  ]
prophecyFramings Person =
  [ "is marked for a martyr's death"
  , "will betray everything they now hold dear"
  , "will outlive everyone who remembers their name"
  , "carries a doom not their own"
  ]
prophecyFramings Site =
  [ "will run red before the season turns"
  , "will be swallowed by the earth"
  , "will be forgotten before it is finished"
  , "will outlast every name now spoken of it"
  ]

-- | Contrary framings for a disputed event, keyed by 'evKind'. Falls back to
-- a generic framing for any kind not listed, so a future event kind never
-- makes reinterpretation crash — only sound blander until it earns entries
-- here.
disputedFramings :: Text -> [Text]
disputedFramings "founding" =
  [ "no founding at all, but a theft of a name already owed elsewhere"
  , "the work of a figure since erased from the record, not the one credited"
  ]
disputedFramings "schism" =
  [ "no split of conviction, but a theft of rank dressed in principle"
  , "an expulsion, not a schism — the departed were cast out, not departed"
  ]
disputedFramings "sanctification" =
  [ "no consecration at all, but land seized under cover of ritual"
  , "a shrine raised to nothing, sanctified over ground already spoken for"
  ]
disputedFramings "battle" =
  [ "no clean victory, but a massacre of those already fleeing"
  , "an ambush, which the victors are careful never to call by that name"
  ]
disputedFramings "purification" =
  [ "no purification, but a defilement dressed in righteous language"
  , "a theft of sanctity, and nothing purified but the claimant's own conscience"
  ]
disputedFramings "miracle" =
  [ "no miracle, but a coincidence dressed up to flatter the faithful"
  , "a trick worked by human hands, not divine ones"
  ]
disputedFramings "assassination" =
  [ "no assassination, but a killing owned up to by cowards who call it justice"
  , "a suicide, dressed up as a murder to make a martyr of the willing dead"
  ]
disputedFramings "merger" =
  [ "no union of the willing, but one body swallowing another whole"
  , "a name kept only to hide a conquest, nothing joined but a debt of blood"
  ]
disputedFramings "dissolution" =
  [ "no natural end, but a silence enforced by enemies who left no witnesses"
  , "no ending at all — a remnant endures still, unrecorded and unclaimed"
  ]
disputedFramings "revival" =
  [ "no true heir, but an opportunist wearing a dead name for cover"
  , "a name borrowed from the fallen to lend weight to something wholly new"
  ]
disputedFramings "prophecy" =
  [ "no true foresight, but a threat dressed up as a vision"
  , "words with nothing behind them, spoken only to be remembered later"
  ]
disputedFramings _ =
  [ "not as it is commonly told" ]
