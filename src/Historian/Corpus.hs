{-# LANGUAGE OverloadedStrings #-}

-- | Training data. Swap these lists to reskin the whole generator.
module Historian.Corpus where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Historian.Types (Culture (..), Kind (..), NameGrammar (..), Predicate (..), VoiceRegister (..))

vaurethine :: Culture
vaurethine = Culture "Vaurethine"

hollowtongue :: Culture
hollowtongue = Culture "Hollowtongue"

-- | Invented, not transliterated — evokes Amharic/Ge'ez phonology (soft,
-- vowel-final syllables, occasional gemination) the same way 'vaureWords'
-- evokes Latin without being real Latin. See Decision 21 in .claude/docs/DESIGN.md.
-- The culture's own label is invented too, not the real ethnonym — see
-- Decision 37: every culture whose *name*, not just its phonology, used to
-- double as a real-world one got renamed the same way 'vaurethine'\/
-- 'hollowtongue' already were.
ethiopian :: Culture
ethiopian = Culture "Ghenzai"

-- | Evokes Sanskrit/Dravidian phonology — consonant clusters, vowel-final
-- roots, common name-forming morphemes ("-endra", "chandra-") used as
-- generic sound-shapes, not any single real name. See Decision 37 for why
-- the culture's own label reads as invented rather than "South Asian".
southAsian :: Culture
southAsian = Culture "Vindrasha"

-- | Evokes Arabic/Hebrew root-and-pattern phonology — the prefixes are
-- genuine cross-family grammatical particles ("al-", "ibn-", "bar-": "the",
-- "son of") rather than any specific person's name, the same register as
-- "Mac-"/"O'-" in a Gaelic-flavored corpus. See Decision 37 for why the
-- culture's own label reads as invented rather than "Semitic".
semitic :: Culture
semitic = Culture "Zabreth"

-- | Evokes Nahuatl/Maya phonology — "tl"/"tz"/"x" clusters, vowel-heavy
-- roots, and "-tzin"/"-tlan" as generic honorific/locative suffix shapes
-- rather than any specific deity or ruler's name. See Decision 37 for why
-- the culture's own label reads as invented rather than "Mesoamerican".
mesoamerican :: Culture
mesoamerican = Culture "Tzalapec"

-- | A joke culture: the Baboons of Caves of Qud, whose entire vocabulary
-- is hooting. No real-world phonology — just vowels, "h", and a very high
-- 'ngHyphenChance' so names read as a chant ("Oo-Ee-Ahoo-Waa"). Not
-- renamed by Decision 37 — it was never a real-world ethnonym to begin
-- with.
baboon :: Culture
baboon = Culture "Baboon"

-- | Invented, evoking East\/Southeast Asian phonology — short, open
-- syllables, soft sibilants, vowel-final — the same "invented label,
-- invented words, real phonological inspiration" discipline as every
-- other culture here (Decision 21\/37). Added purely to widen merge\/
-- split's own starting palette (work item 26 §5), the same reason
-- 'ohanaki'\/'volnisk' exist.
xanuvei :: Culture
xanuvei = Culture "Xanuvei"

-- | Invented, evoking Polynesian\/Austronesian phonology — vowel-heavy,
-- reduplicated-feeling syllables, no consonant clusters.
ohanaki :: Culture
ohanaki = Culture "Ohanaki"

-- | Invented, evoking Slavic\/Baltic phonology — consonant clusters,
-- "-sk"\/"-ov"\/"-en"-style endings.
volnisk :: Culture
volnisk = Culture "Volnisk"

allCultures :: [Culture]
allCultures = [vaurethine, hollowtongue, ethiopian, southAsian, semitic, mesoamerican, baboon, xanuvei, ohanaki, volnisk]

-- | Total by construction: an unrecognised culture falls back rather than
-- crashing, which matters once cultures are minted at runtime.
corpusFor :: Culture -> [String]
corpusFor (Culture "Hollowtongue") = hollowWords
corpusFor (Culture "Ghenzai") = ethiopianWords
corpusFor (Culture "Vindrasha") = southAsianWords
corpusFor (Culture "Zabreth") = semiticWords
corpusFor (Culture "Tzalapec") = mesoamericanWords
corpusFor (Culture "Baboon") = baboonWords
corpusFor (Culture "Xanuvei") = xanuveiWords
corpusFor (Culture "Ohanaki") = ohanakiWords
corpusFor (Culture "Volnisk") = volniskWords
corpusFor _ = vaureWords

vaureWords :: [String]
vaureWords =
  [ "vaurethine"
  , "ossilane"
  , "thessomar"
  , "viremundis"
  , "calcedon"
  , "aurelith"
  , "sarravent"
  , "mendicorum"
  , "tenebris"
  , "solvantine"
  , "quirethis"
  , "palladine"
  , "umbracine"
  , "cinerion"
  , "velluthar"
  , "ostravane"
  , "ferrasine"
  , "lucivane"
  , "arcanthos"
  , "ravellion"
  , "silaurent"
  , "thaumine"
  , "obscurine"
  , "veridane"
  , "malacor"
  , "sanctorine"
  , "ignivault"
  , "corvassine"
  , "ambroselle"
  , "nectarion"
  ]

hollowWords :: [String]
hollowWords =
  [ "grendleth"
  , "harrowkin"
  , "orbeck"
  , "thrangar"
  , "kelduth"
  , "morwick"
  , "dregmar"
  , "valthok"
  , "skerrand"
  , "bruthan"
  , "hagvold"
  , "ormsgate"
  , "tarrowen"
  , "gethrune"
  , "drossick"
  , "kaldbrek"
  , "vennrath"
  , "wormgeld"
  , "stakhold"
  , "thelgrim"
  , "morgath"
  , "ruskvane"
  , "ohtberd"
  , "wexholt"
  , "gnarlend"
  , "brimmoth"
  , "haldreck"
  , "stennvar"
  , "ulgareth"
  , "fennwick"
  ]

ethiopianWords :: [String]
ethiopianWords =
  [ "makelaba"
  , "tesharu"
  , "zenawit"
  , "abegazu"
  , "haruken"
  , "dolvanu"
  , "kedasha"
  , "werabu"
  , "lomeshu"
  , "nadefan"
  , "chereku"
  , "malkuta"
  , "sebahle"
  , "toregan"
  , "wubante"
  , "kirasu"
  , "damalu"
  , "fenoteb"
  , "harkuze"
  , "selamun"
  , "gerimot"
  , "yohanu"
  , "tekleba"
  , "worsanu"
  , "abrahat"
  ]

southAsianWords :: [String]
southAsianWords =
  [ "chandravat"
  , "suryaketu"
  , "ravindanu"
  , "devakiran"
  , "priyantar"
  , "vasanthu"
  , "indralok"
  , "mahavira"
  , "keshalan"
  , "balaruna"
  , "tarashiv"
  , "senaputra"
  , "aranyaka"
  , "nirmalesh"
  , "kashyapan"
  , "vidyantar"
  , "harishtra"
  , "amarendu"
  , "sudarshan"
  , "vikramesh"
  , "lakshaven"
  , "manohara"
  , "ushanidra"
  , "girijant"
  ]

semiticWords :: [String]
semiticWords =
  [ "karashim"
  , "zahranu"
  , "tammuzar"
  , "nadikesh"
  , "sulayfar"
  , "yazidane"
  , "qadirun"
  , "fahrizan"
  , "zairuman"
  , "hamalik"
  , "rashiddu"
  , "tabaresh"
  , "medanzar"
  , "sharafin"
  , "kadeshan"
  , "amirzuf"
  , "baraket"
  , "dahiruz"
  , "nasirkan"
  , "faridesh"
  , "malachim"
  , "eliyazar"
  , "shomarin"
  , "tirzanek"
  ]

mesoamericanWords :: [String]
mesoamericanWords =
  [ "xochitepan"
  , "cuauhtemal"
  , "tlacayotl"
  , "itzamahue"
  , "nahuiteca"
  , "metzcoatl"
  , "panohuitz"
  , "tototlan"
  , "chalcazin"
  , "yaotecuh"
  , "coyolapan"
  , "tlanextiz"
  , "xolomitl"
  , "cuetlaxan"
  , "mictlazu"
  , "teponaztl"
  , "xicotenca"
  , "ahuizotan"
  , "necahual"
  , "tlalocan"
  , "quetzavan"
  , "huitecalt"
  , "moyotepec"
  , "acamapiz"
  ]

-- | Every "word" is just chained hooting — there is no phonology to
-- respect here, only vowels and breath.
baboonWords :: [String]
baboonWords =
  [ "oowahoo"
  , "eehoowa"
  , "ahoowee"
  , "oohaeeoo"
  , "waheeoo"
  , "eeohaah"
  , "oohooee"
  , "aeeohoo"
  , "hooeewa"
  , "oowaheea"
  , "eeoowah"
  , "ahoeewa"
  , "oohaeewa"
  , "waeehoo"
  , "eeahoowa"
  , "oohoowee"
  , "aaheeoo"
  , "wooeeha"
  , "eehaoowa"
  , "oowaheeoo"
  ]

xanuveiWords :: [String]
xanuveiWords =
  [ "shanrei"
  , "meiruko"
  , "kaosen"
  , "tanrei"
  , "linzao"
  , "saemoto"
  , "waitoshi"
  , "renkao"
  , "mairu"
  , "hanzei"
  , "toaren"
  , "shumako"
  , "kailen"
  , "renzou"
  , "tosane"
  , "shuzao"
  , "kaimeru"
  , "wanreo"
  , "seiruko"
  , "noalin"
  , "raemoto"
  ]

ohanakiWords :: [String]
ohanakiWords =
  [ "manaoa"
  , "tokoroa"
  , "hinalei"
  , "waikona"
  , "fanoa"
  , "teimana"
  , "roahiti"
  , "kailoa"
  , "nohea"
  , "manawai"
  , "tokoloa"
  , "hialani"
  , "faroa"
  , "teahiwa"
  , "koaloa"
  , "nianoa"
  , "waikoa"
  , "tohana"
  , "roakea"
  , "fanui"
  , "hinaroa"
  ]

volniskWords :: [String]
volniskWords =
  [ "bronivosk"
  , "vetrogorsk"
  , "zdenomir"
  , "krivosek"
  , "dobrenko"
  , "yaroslen"
  , "mirosk"
  , "stanivoy"
  , "bezrodin"
  , "chernavik"
  , "gorislen"
  , "velemirsk"
  , "dragomil"
  , "kostrovan"
  , "yarovek"
  , "bratislen"
  , "voronsk"
  , "milogorod"
  , "zdravoysk"
  , "ostravik"
  , "radomisk"
  , "tveresk"
  ]

-- | 'NameGrammar' itself now lives in 'Historian.Types' — 'World' needs to
-- reference it ('wGrammars', work item 26) and 'Historian.Types' sits below
-- this module, so the type moved the same way 'Tuning' did (Decision 42).
-- What stays here: every built-in culture's own grammar value, and the
-- total dispatch function below, mirroring 'corpusFor' exactly.
nameGrammarFor :: Culture -> NameGrammar
nameGrammarFor (Culture "Hollowtongue") = hollowGrammar
nameGrammarFor (Culture "Ghenzai") = ethiopianGrammar
nameGrammarFor (Culture "Vindrasha") = southAsianGrammar
nameGrammarFor (Culture "Zabreth") = semiticGrammar
nameGrammarFor (Culture "Tzalapec") = mesoamericanGrammar
nameGrammarFor (Culture "Baboon") = baboonGrammar
nameGrammarFor (Culture "Xanuvei") = xanuveiGrammar
nameGrammarFor (Culture "Ohanaki") = ohanakiGrammar
nameGrammarFor (Culture "Volnisk") = volniskGrammar
nameGrammarFor _ = vaureGrammar

-- | Smooth and Latinate, matching 'vaureWords'\'s liquid consonants and
-- vowel-heavy endings. A low hyphen chance keeps names flowing rather than
-- compound-sounding.
vaureGrammar :: NameGrammar
vaureGrammar =
  NameGrammar
    { ngPrefixes = ["vel", "os", "cal", "sil", "aur", "sar", "quir", "ig", "ner", "luc"]
    , ngRoots = ["an", "or", "ith", "ane", "vane", "rel", "sor", "lith", "mor", "cin", "dane", "ren", "ell", "vant"]
    , ngSuffixes = ["ine", "ith", "or", "ane", "us", "yn"]
    , ngMaxSyllables = 3
    , ngPrefixChance = 45
    , ngSuffixChance = 65
    , ngHyphenChance = 10
    }

-- | Blunt and Norse-flavored, matching 'hollowWords'\'s harder clusters
-- and compound-sounding endings. A high hyphen chance is part of the
-- culture's feel — this is what produces "Grendl-Kaddur"-style names.
hollowGrammar :: NameGrammar
hollowGrammar =
  NameGrammar
    { ngPrefixes = ["gren", "har", "thran", "kel", "morw", "val", "sker", "brut", "hag", "orm"]
    , ngRoots = ["dleth", "kin", "beck", "gar", "duth", "wick", "thok", "rand", "vold", "gate", "rune", "brek", "geld", "grim"]
    , ngSuffixes = ["eth", "ick", "ar", "ok", "und", "holt"]
    , ngMaxSyllables = 2
    , ngPrefixChance = 60
    , ngSuffixChance = 45
    , ngHyphenChance = 35
    }

-- | Soft and vowel-final, matching 'ethiopianWords'. A middling hyphen
-- chance gives an occasional compound feel without it dominating.
ethiopianGrammar :: NameGrammar
ethiopianGrammar =
  NameGrammar
    { ngPrefixes = ["ge", "ha", "ke", "te", "ze", "wa", "da", "le", "ma", "sa"]
    , ngRoots = ["bere", "kelu", "tash", "wale", "zena", "desha", "hara", "mulu", "kidu", "senay", "worka", "geleta"]
    , ngSuffixes = ["u", "e", "a", "am", "ay", "esh"]
    , ngMaxSyllables = 2
    , ngPrefixChance = 55
    , ngSuffixChance = 60
    , ngHyphenChance = 15
    }

-- | Longer, more melodic chains than any other culture here, matching
-- 'southAsianWords'\'s consonant clusters and vowel-final roots. The
-- lowest hyphen chance of any culture — compounding reads as un-Sanskritic.
southAsianGrammar :: NameGrammar
southAsianGrammar =
  NameGrammar
    { ngPrefixes = ["chan", "sur", "rav", "dev", "pri", "ma", "in", "vas", "shi", "ana"]
    , ngRoots = ["dra", "esh", "ant", "vira", "lok", "tara", "mitra", "raja", "sena", "priya", "bala", "kesh"]
    , ngSuffixes = ["a", "i", "an", "esh", "ita", "endra"]
    , ngMaxSyllables = 3
    , ngPrefixChance = 50
    , ngSuffixChance = 70
    , ngHyphenChance = 8
    }

-- | Root-and-pattern consonant clusters, matching 'semiticWords'. The
-- prefixes here are genuine cross-family grammatical particles ("the",
-- "son of", "father of", "mother of") rather than any specific name.
semiticGrammar :: NameGrammar
semiticGrammar =
  NameGrammar
    { ngPrefixes = ["al", "ibn", "abu", "umm", "bar", "ben", "zu", "ha"]
    , ngRoots = ["kar", "hal", "sim", "zah", "rash", "tam", "nadi", "sulay", "yaz", "qad", "fahr", "zair"]
    , ngSuffixes = ["im", "el", "an", "iyya", "ir", "ah"]
    , ngMaxSyllables = 3
    , ngPrefixChance = 40
    , ngSuffixChance = 55
    , ngHyphenChance = 10
    }

-- | Blunt "tl"\/"tz"\/"x" clusters, matching 'mesoamericanWords'. A high
-- hyphen chance gives the compound-honorific feel real Nahuatl names have
-- ("Xochi-Tepec"-style), without literally reusing one.
mesoamericanGrammar :: NameGrammar
mesoamericanGrammar =
  NameGrammar
    { ngPrefixes = ["cu", "xo", "te", "tla", "chi", "itz", "na", "co", "ma", "yao"]
    , ngRoots = ["choch", "tepe", "cali", "metz", "zolo", "panu", "toto", "cuau", "nahu", "tlan"]
    , ngSuffixes = ["tl", "tzin", "co", "pan", "otl", "itl"]
    , ngMaxSyllables = 2
    , ngPrefixChance = 55
    , ngSuffixChance = 65
    , ngHyphenChance = 20
    }

-- | The highest hyphen chance and syllable cap of any culture: a longer
-- chain of hooted syllables reads as a chant ("Oo-Ee-Ahoo-Waa"), the point.
baboonGrammar :: NameGrammar
baboonGrammar =
  NameGrammar
    { ngPrefixes = ["oo", "ee", "ah", "oh", "wa", "hoo", "aa", "wee"]
    , ngRoots = ["oo", "ee", "ah", "oh", "hoo", "waa", "eek", "aoo", "ohh", "eeh"]
    , ngSuffixes = ["oo", "ee", "ah", "ooh", "eeh", "waa"]
    , ngMaxSyllables = 4
    , ngPrefixChance = 55
    , ngSuffixChance = 55
    , ngHyphenChance = 70
    }

-- | Short, open, vowel-final syllables and soft sibilants, matching
-- 'xanuveiWords'. A low hyphen chance keeps names reading as smooth,
-- unbroken syllable runs rather than compounds.
xanuveiGrammar :: NameGrammar
xanuveiGrammar =
  NameGrammar
    { ngPrefixes = ["sha", "mei", "kao", "ren", "lin", "sae", "tao", "wai", "han", "sei"]
    , ngRoots = ["rei", "ruko", "sen", "zao", "moto", "toshi", "kao", "ru", "nae", "zou"]
    , ngSuffixes = ["a", "i", "o", "ei", "an", "u"]
    , ngMaxSyllables = 2
    , ngPrefixChance = 50
    , ngSuffixChance = 60
    , ngHyphenChance = 5
    }

-- | Vowel-heavy, no consonant clusters, matching 'ohanakiWords' — the
-- longest syllable cap of any non-Baboon culture gives names a
-- reduplicated, chant-like feel without literally repeating a syllable
-- the way Baboon's own grammar does.
ohanakiGrammar :: NameGrammar
ohanakiGrammar =
  NameGrammar
    { ngPrefixes = ["ma", "na", "ka", "lo", "hi", "fa", "wai", "noa", "tea", "roa"]
    , ngRoots = ["noa", "hiti", "kona", "lei", "waia", "mana", "roa", "tahi", "wana", "kea"]
    , ngSuffixes = ["a", "i", "o", "ea", "oa", "ai"]
    , ngMaxSyllables = 3
    , ngPrefixChance = 40
    , ngSuffixChance = 55
    , ngHyphenChance = 5
    }

-- | Consonant clusters and "-sk"\/"-ov"\/"-en"-style endings, matching
-- 'volniskWords'. A moderately high hyphen chance gives the compound-place-
-- name feel real Slavic\/Baltic toponyms have.
volniskGrammar :: NameGrammar
volniskGrammar =
  NameGrammar
    { ngPrefixes = ["bron", "vetro", "zdeno", "krivo", "dobren", "yaros", "mir", "stani", "bezro", "cherna"]
    , ngRoots = ["grad", "mir", "sek", "enko", "slen", "osk", "voy", "din", "vik", "gorod"]
    , ngSuffixes = ["sk", "ov", "en", "in", "ek", "grad"]
    , ngMaxSyllables = 2
    , ngPrefixChance = 60
    , ngSuffixChance = 65
    , ngHyphenChance = 25
    }

societyEpithets :: [Text]
societyEpithets =
  [ "Sundered"
  , "Ashen"
  , "Veiled"
  , "Ninefold"
  , "Weeping"
  , "Silent"
  , "Gilded"
  , "Hollow"
  , "Thrice-Bound"
  , "Unwritten"
  ]

societyNouns :: [Text]
societyNouns =
  [ "Concordance"
  , "Choir"
  , "Assembly"
  , "Covenant"
  , "Lantern"
  , "Vigil"
  , "Cenacle"
  , "Fraternity"
  , "Congregation"
  , "Order"
  , "Society"
  , "Otherhood"
  , "Sisterhood"
  , "Brotherhood"
  ]

siteNouns :: [Text]
siteNouns =
  [ "Column"
  , "Ossuary"
  , "Bridge"
  , "Gate"
  , "Wellhead"
  , "Terrace"
  , "Reliquary"
  , "Barrow"
  , "Cistern"
  , "Stair"
  , "Ruins"
  , "Temple"
  , "Tower"
  , "Tor"
  , "Mountain"
  , "Dungeon"
  , "Bailey"
  , "Barrio"
  , "Library"
  , "Hospital"
  ]

-- | 'Historian.World.siteNounFor's "built" branch — a site whose origin
-- backstory is deliberate construction, not discovery. Distinct from the
-- unflavored 'siteNouns' above rather than a subset of it, so neither
-- list needs re-auditing for which of its existing entries already leans
-- one way or the other.
constructedSiteNouns :: [Text]
constructedSiteNouns =
  [ "Hall"
  , "Vault"
  , "Bastion"
  , "Cloister"
  , "Archive"
  , "Foundry"
  , "Rampart"
  , "Scriptorium"
  ]

-- | 'Historian.World.siteNounFor's "discovered" branch — a natural
-- feature later sanctified, not built.
naturalSiteNouns :: [Text]
naturalSiteNouns =
  [ "Grotto"
  , "Spring"
  , "Hollow"
  , "Cavern"
  , "Grove"
  , "Fen"
  , "Hotspring"
  , "Sinkhole"
  ]

itemNouns :: [Text]
itemNouns =
  [ "Chalice"
  , "Shroud"
  , "Crown"
  , "Blade"
  , "Censer"
  , "Effigy"
  , "Codex"
  , "Mask"
  , "Girdle"
  , "Relic"
  , "Gloves"
  , "Sword"
  , "Dagger"
  , "Axe"
  , "Flail"
  , "Shield"
  , "Hood"
  , "Greaves"
  , "Gauntlet"
  , "Jerkin"
  , "Helm"
  , "Mace"
  , "Sceptre"
  , "Bow"
  , "Sling"
  , "Dragoon"
  , "Lance"
  , "Dakimakura"
  ]

-- | Adjectives for the item half of 'Historian.World.societyModifier's
-- naming grammar — a physical/mystical register (condition, provenance)
-- distinct from 'societyEpithets's more abstract one, so a cult named for
-- a relic reads differently from one named for an abstract quality.
itemEpithets :: [Text]
itemEpithets =
  [ "Bleeding"
  , "Blackened"
  , "Cracked"
  , "Bound"
  , "Whispering"
  , "Rusted"
  , "Drowned"
  , "Forgotten"
  , "Anointed"
  , "Splintered"
  ]

-- | A dying curse's own framing — deliberately flat, not indexed by
-- 'Kind' like 'prophecyFramings': a curse's "may you be shunned" register
-- reads naturally against a society, a person, or an item alike. Always
-- paired with the 'Shuns' omen ('Historian.Rules.fireDyingWords').
-- 'NonEmpty' so 'fireDyingWords' can take the head as its own fallback
-- instead of a separate literal.
curseFramings :: NonEmpty Text
curseFramings =
  "will be shunned by all who once called them kin"
    :| [ "will find no ally when the reckoning comes"
       , "will be cursed in every mouth that speaks their name"
       , "will watch everything they hold dear turn away"
       ]

-- | Idiosyncratic dressing pools for 'Historian.Render.applyIdiosyncrasies'
-- — independent of 'VoiceRegister' (that's a lexical substitution axis;
-- this is a post-processing one, see .claude/docs/DESIGN.md Decision 34). A
-- recurring exclamation a narrator opens with, regardless of what's being
-- reported.
hailWords :: NonEmpty Text
hailWords =
  "Hark!"
    :| [ "Mark this well:"
       , "Hear us now:"
       , "Attend:"
       , "Let it be known:"
       ]

-- | A rambling aside a narrator tacks onto the end of an account —
-- meaning nothing, committing to nothing, the idiosyncratic opposite of a
-- clean report.
meanderClauses :: NonEmpty Text
meanderClauses =
  "though the details blur with every retelling"
    :| [ "or so three separate accounts agree, more or less"
       , "the exact order of things already disputed among the faithful"
       , "as much as anyone still living can attest to it"
       , "though who first spoke of it, nobody now recalls"
       ]

-- | What gets recorded in place of the narration when a narrator simply
-- declines to elaborate — still real 'Text' (invariant 3 gives
-- 'evNarratedText' no 'Maybe'), just a non-committal stand-in rather than
-- the actual account.
omissionTexts :: NonEmpty Text
omissionTexts =
  "..."
    :| [ "The full account goes unrecorded."
       , "Nothing further is said of it."
       , "The rest is passed over in silence."
       ]

-- | A cult's writing register, substituted into the neutral sentence
-- templates for the three outcome types migrated to voiced rendering so
-- far ('Historian.Render.renderWithVoice') — reusing the same voice's own
-- verb phrase wherever the neutral template repeats one (e.g.
-- 'miracleSaintVoicing' across 'MiracleSaint's three sub-cases), same
-- shape as 'curseFramings'/'disputedFramings'.
foundingVoicing :: VoiceRegister -> Text
foundingVoicing = \case
  Plain -> "was founded by"
  Fervent -> "was raised up in fire by"
  Grim -> "was first named in blood by"

miracleSaintVoicing :: VoiceRegister -> Text
miracleSaintVoicing = \case
  Plain -> "proclaims a miracle at"
  Fervent -> "calls down a burning wonder upon"
  Grim -> "reads a bone-sign into"

-- | The two connective phrases 'Schism's "fresh" template needs — see
-- 'schismRenouncedVoicing' for its other branch.
schismFreshVoicing :: VoiceRegister -> (Text, Text)
schismFreshVoicing = \case
  Plain -> ("broke from", "and took the name")
  Fervent -> ("tore free of", "and was reborn as")
  Grim -> ("cut itself loose from", "and took up the name")

schismRenouncedVoicing :: VoiceRegister -> (Text, Text)
schismRenouncedVoicing = \case
  Plain -> ("renounced", "and led the dissent out as")
  Fervent -> ("cast off", "and led the faithful out as")
  Grim -> ("turned against", "and led the broken out as")

-- | The symbolic properties a relic can embody, and by extension what a
-- cult can independently venerate or shun as a 'Concept' in its own right
-- (see 'Historian.World.conceptNamed'). Split into categories for texture
-- even though 'conceptNames' picks across all of them flat — elements,
-- minerals, nature, magical concepts, animals, monsters, and a handful of
-- mundane or wacky things, so a relic's nature isn't always high fantasy.
elementConcepts :: [Text]
elementConcepts =
  ["Fire", "Frost", "Ash", "Storm", "the Tide", "the Void"]

mineralConcepts :: [Text]
mineralConcepts =
  ["Iron", "Salt", "Obsidian", "Amber", "Quartz", "Lead", "Crystal", "Steel", "Bronze", "Chrome", "Ceramic"]

natureConcepts :: [Text]
natureConcepts =
  ["Oak", "Bramble", "Marsh", "Harvest", "Frost-Line", "Deep Root", "Toadstool", "Slime", "Coral"]

magicalConcepts :: [Text]
magicalConcepts =
  ["Unseen Hour", "Second Sight", "Bound Name", "Long Dream", "Hollow Word", "Witch", "Warlock", "Apotropeai"]

animalConcepts :: [Text]
animalConcepts =
  ["Wolf", "Raven", "Serpent", "Stag", "Octopus", "Snail", "Moth", "Eel", "Cat", "Hound", "Lion", "Gibbon", "Toad"]

monsterConcepts :: [Text]
monsterConcepts =
  ["Drowned King", "Many-Handed", "the Wormwood Thing", "Gnawing Dark"]

mundaneConcepts :: [Text]
mundaneConcepts =
  ["Ledger", "Broken Wheel", "Debt", "Empty Chair", "Second Helping", "Woodworking"]

mathsConcepts :: [Text]
mathsConcepts =
  ["Rhombus", "Monad", "Calculus", "Divisor", "Long Divison", "Presheaf"]

conceptNames :: [Text]
conceptNames =
  elementConcepts
    ++ mineralConcepts
    ++ natureConcepts
    ++ magicalConcepts
    ++ animalConcepts
    ++ monsterConcepts
    ++ mundaneConcepts
    ++ mathsConcepts

-- | 'Historian.World.newMundanePerson's filler text — a bystander a
-- miracle happens near, not a name: no culture, no phonology, no byname.
-- Deliberately plain register (contrast 'bynames'), so it reads as the
-- opposite of a proper name on sight.
mundanePersons :: [Text]
mundanePersons =
  [ "a young widow"
  , "an old fisherman"
  , "a passing pilgrim"
  , "a bewildered goatherd"
  , "a tired midwife"
  , "a one-armed beggar"
  , "a travelling tinker"
  , "a sleepless watchman"
  , "a drunk gravedigger"
  , "a child gathering firewood"
  , "a limping shepherd"
  , "a market-day thief"
  , "a mute laundress"
  , "a half-blind scribe"
  , "a footsore courier"
  ]

-- | 'Historian.World.newMundaneItem's filler text — a prop, not a relic:
-- no stem, no noun-of-stem grammar, nothing 'themedItemName' could ever
-- catch onto.
mundaneItems :: [Text]
mundaneItems =
  [ "a rusty spoon"
  , "a cracked water jug"
  , "a moth-eaten blanket"
  , "a length of frayed rope"
  , "a broken cartwheel"
  , "a tallow candle stub"
  , "a chipped clay bowl"
  , "a bent iron nail"
  , "a threadbare sandal"
  , "a stray dog's collar"
  , "a warped wooden ladle"
  , "a torn fishing net"
  , "a handful of spilled grain"
  , "a cracked roof tile"
  , "a stub of chalk"
  ]

bynames :: [Text]
bynames =
  [ "the Younger"
  , "the Elder"
  , "the Fecund"
  , "the Unmarred"
  , "the Twice-Buried"
  , "of the Low Choir"
  , "the Recanter"
  , "the Blind"
  , "the Unshriven"
  , "the Handless"
  , "the Wise"
  , "the Uncouth"
  , "the Dark"
  , "the Light"
  , "the Grey"
  , "the Homie"
  , "One-Eye"
  ]

-- | A cult's day-to-day practice or ritual — template-fill, not a new
-- Markov register (invariant 6: Markov output is for proper-noun stems
-- only, never sentences), one function per frame taking whatever's
-- already known about the cult (its patron 'Concept', a currently
-- venerated\/shunned Ward, or a held relic's name — 'Historian.World.
-- practiceText's caller picks which) and splicing it in, same
-- concatenation style 'Historian.World.themedItemName'\/'baneName'
-- already use rather than a printf-style placeholder. One list per
-- 'VoiceRegister', the same lexical-substitution axis 'foundingVoicing'\/
-- 'miracleSaintVoicing' already establish — a 'Fervent' cult's practices
-- read more devout, a 'Grim' cult's read starker, around the same
-- underlying slot. Work item 24, Tier 2:
-- @.claude/docs/plans/24-ttrpg-cult-export.md@ §3.
practiceFrames :: VoiceRegister -> NonEmpty (Text -> Text)
practiceFrames = \case
  Plain ->
    (\f -> "They keep a small shrine to " <> f <> " in every household.")
      :| [ \f -> "Newcomers are asked to name " <> f <> " before they may speak in council."
         , \f -> "Every gathering opens with a recitation naming " <> f <> "."
         , \f -> "They mark the turning of each season by invoking " <> f <> "."
         , \f -> "A portion of every meal is set aside for " <> f <> "."
         , \f -> "Disputes among them are settled by an oath sworn on " <> f <> "."
         ]
  Fervent ->
    (\f -> "They burn offerings to " <> f <> " at every new moon.")
      :| [ \f -> "Novices are branded with a sign of " <> f <> " before they may join."
         , \f -> "They march in procession, chanting the name of " <> f <> ", on the high days."
         , \f -> "Every vow taken among them is sworn upon " <> f <> "."
         , \f -> "They fast for three days before speaking of " <> f <> " aloud."
         , \f -> "The faithful scar themselves in the shape of " <> f <> " to mark their devotion."
         ]
  Grim ->
    (\f -> "They cut a mark into the door lintel for " <> f <> " and never explain why.")
      :| [ \f -> "The dying are carried past a shrine to " <> f <> " before burial."
         , \f -> "They keep silence on the anniversary of whatever wronged " <> f <> "."
         , \f -> "Debts among them are settled in the name of " <> f <> ", never in coin."
         , \f -> "Children are not told of " <> f <> " until they've lost someone."
         , \f -> "They bury a coin with every dead, an old debt owed to " <> f <> "."
         ]

-- | Calendar month names are "{adjective} {noun}", with an optional
-- trailing ", {epithet}" — "Dancing Butcher" or "Eastern Child, Turning".
-- Deliberately a different register from the society/site word lists
-- above: a calendar should feel folk and seasonal, not institutional.
monthAdjectives :: [Text]
monthAdjectives =
  [ "Dancing"
  , "Eastern"
  , "Weeping"
  , "Drowned"
  , "Hollow"
  , "Bleeding"
  , "Silent"
  , "Gilded"
  , "Withered"
  , "Waking"
  , "Fasting"
  , "Nameless"
  , "Shivering"
  , "Glittering"
  ]

monthNouns :: [Text]
monthNouns =
  [ "Butcher"
  , "Child"
  , "Harvest"
  , "Wolf"
  , "Ember"
  , "Tide"
  , "Bell"
  , "Thorn"
  , "Widow"
  , "Lantern"
  , "Serpent"
  , "Ash"
  , "Mouse"
  , "Knife"
  , "Man"
  , "Woman"
  , "Moon"
  , "Sun"
  , "Star"
  ]

monthEpithets :: [Text]
monthEpithets =
  [ "Turning"
  , "Waning"
  , "Ascendant"
  , "Reversed"
  , "Unbound"
  , "Drowning"
  , "Silent"
  , "Descending"
  ]

-- | Names for the single named era a world's calendar reckons from —
-- "Year 5 After the Sundering", "Year -3 of the Long Silence". One era per
-- world, chosen once; see 'Historian.World.calendarParams'.
eraNames :: [Text]
eraNames =
  [ "the Sundering"
  , "the Reckoning"
  , "the Long Silence"
  , "the First Betrayal"
  , "the Drowning"
  , "the Unmaking"
  , "the Ashen Peace"
  , "the Turning"
  , "the Hollow Accord"
  , "the Last Kindling"
  ]

-- | What a prophecy foretells, keyed by the kind of thing it's about, each
-- line paired with the 'Predicate' whose future assertion about the target
-- fulfills it (see 'Historian.Rules.omenOf'/'fulfillProphecies') —
-- 'Nothing' for a line with no honest mechanical match, which stays purely
-- rhetorical. Excludes 'Grievance'\/'Venerates'\/'Reconciled' as omens
-- deliberately: they fire so constantly via unrelated rules that using them
-- would make "fulfilled" nearly meaningless.
prophecyFramings :: Kind -> [(Maybe Predicate, Text)]
prophecyFramings Society =
  [ (Just Terminated, "will fall to ruin within a generation")
  , (Just SplitFrom, "will be torn apart from within")
  , (Just MergedInto, "will forget the name of its own founder")
  , (Just MergedInto, "will be the death of everything it claims to protect")
  ]
prophecyFramings Person =
  [ (Just Slain, "is marked for a martyr's death")
  , (Just Heretic, "will betray everything they now hold dear")
  , (Nothing, "will outlive everyone who remembers their name")
  , (Nothing, "carries a doom not their own")
  ]
prophecyFramings Site =
  [ (Just BattledAt, "will run red before the season turns")
  , (Nothing, "will be swallowed by the earth")
  , (Nothing, "will be forgotten before it is finished")
  , (Just Sanctified, "will outlast every name now spoken of it")
  ]
prophecyFramings Item =
  [ (Nothing, "will pass through a hundred unworthy hands")
  , (Just Terminated, "will be shattered by whoever claims it next")
  , (Nothing, "will outlast the faith that first raised it up")
  , (Just Terminated, "will be melted down and remembered as something else")
  ]
prophecyFramings Concept = []

-- | Fallback for a 'Kind' with no framings of its own (currently just
-- 'Concept', which 'Historian.Rules.ruleProphesy' never targets, so this
-- never actually fires). Kept here rather than a literal in
-- 'Historian.Rules' so all prose stays in one place.
defaultFraming :: (Maybe Predicate, Text)
defaultFraming = (Nothing, "will not see another dawn")

-- | Contrary framings for a disputed event, keyed by 'evKind'. Falls back
-- to a generic framing for any kind not listed, so a future event kind
-- never makes disputing crash — only sound blander until it earns entries
-- here. 'NonEmpty' for the same reason as 'curseFramings'.
disputedFramings :: Text -> NonEmpty Text
disputedFramings "founding" =
  "no founding at all, but a theft of a name already owed elsewhere"
    :| ["the work of a figure since erased from the record, not the one credited"]
disputedFramings "schism" =
  "no split of conviction, but a theft of rank dressed in principle"
    :| ["an expulsion, not a schism — the departed were cast out, not departed"]
disputedFramings "sanctification" =
  "no consecration at all, but land seized under cover of ritual"
    :| ["a shrine raised to nothing, sanctified over ground already spoken for"]
disputedFramings "battle" =
  "no clean victory, but a massacre of those already fleeing"
    :| ["an ambush, which the victors are careful never to call by that name"]
disputedFramings "purification" =
  "no purification, but a defilement dressed in righteous language"
    :| ["a theft of sanctity, and nothing purified but the claimant's own conscience"]
disputedFramings "miracle" =
  "no miracle, but a coincidence dressed up to flatter the faithful"
    :| ["a trick worked by human hands, not divine ones"]
disputedFramings "assassination" =
  "no assassination, but a killing owned up to by cowards who call it justice"
    :| ["a suicide, dressed up as a murder to make a martyr of the willing dead"]
disputedFramings "merger" =
  "no union of the willing, but one body swallowing another whole"
    :| ["a name kept only to hide a conquest, nothing joined but a debt of blood"]
disputedFramings "dissolution" =
  "no natural end, but a silence enforced by enemies who left no witnesses"
    :| ["no ending at all — a remnant endures still, unrecorded and unclaimed"]
disputedFramings "revival" =
  "no true heir, but an opportunist wearing a dead name for cover"
    :| ["a name borrowed from the fallen to lend weight to something wholly new"]
disputedFramings "prophecy" =
  "no true foresight, but a threat dressed up as a vision"
    :| ["words with nothing behind them, spoken only to be remembered later"]
disputedFramings "cataclysm" =
  -- Entry kept for symmetry with every other kind, even though nothing
  -- calls 'Historian.Rules.maybeDispute' for a cataclysm in this first
  -- pass — see work item 26 §7 for why: no single natural disputant for a
  -- world-scale event, the same precedent 'ruleDissolve' already set.
  "no cataclysm at all, but an old order's own ruin dressed up as fate"
    :| ["a reckoning too convenient to be anything but arranged"]
disputedFramings _ = "not as it is commonly told" :| []
