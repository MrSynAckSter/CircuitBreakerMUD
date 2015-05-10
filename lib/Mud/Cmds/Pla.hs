{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase, MonadComprehensions, MultiWayIf, NamedFieldPuns, OverloadedStrings, ParallelListComp, PatternSynonyms, RecordWildCards, TransformListComp, ViewPatterns #-}

module Mud.Cmds.Pla ( getRecordUptime
                    , getUptime
                    , go
                    , handleEgress
                    , look
                    , plaCmds
                    , showMotd ) where

import Mud.Cmds.ExpCmds
import Mud.Cmds.Util.Abbrev
import Mud.Cmds.Util.Misc
import Mud.Cmds.Util.Pla
import Mud.Data.Misc
import Mud.Data.State.ActionParams.ActionParams
import Mud.Data.State.ActionParams.Util
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Misc.ANSI
import Mud.Misc.Logging hiding (logNotice, logPla, logPlaExec, logPlaExecArgs, logPlaOut)
import Mud.Misc.NameResolution
import Mud.TheWorld.Ids
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.FilePaths
import Mud.TopLvlDefs.Misc
import Mud.Util.List
import Mud.Util.Misc hiding (patternMatchFail)
import Mud.Util.Padding
import Mud.Util.Quoting
import Mud.Util.Text
import Mud.Util.Token
import Mud.Util.Wrapping
import qualified Mud.Misc.Logging as L (logNotice, logPla, logPlaExec, logPlaExecArgs, logPlaOut)
import qualified Mud.Util.Misc as U (patternMatchFail)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((***), first)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Control.Exception.Lifted (catch, try)
import Control.Lens (_1, _2, _3, _4, at, both, to, view, views)
import Control.Lens.Operators ((%~), (&), (.~), (<>~), (.~), (^.))
import Control.Monad ((>=>), forM, forM_, guard, mplus, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Char (isDigit)
import Data.Function (on)
import Data.IntMap.Lazy ((!))
import Data.Ix (inRange)
import Data.List ((\\), delete, foldl', intercalate, intersperse, nub, nubBy, partition, sort, sortBy, unfoldr)
import Data.List.Split (chunksOf)
import Data.Maybe (fromJust)
import Data.Monoid ((<>), Sum(..), mempty)
import GHC.Exts (sortWith)
import Prelude hiding (pi)
import System.Clock (Clock(..), TimeSpec(..), getTime)
import System.Console.ANSI (ColorIntensity(..), clearScreenCode)
import System.Directory (doesFileExist, getDirectoryContents)
import System.FilePath ((</>))
import System.Time.Utils (renderSecs)
import qualified Data.Map.Lazy as M ((!), elems, filter, lookup, null)
import qualified Data.Set as S (filter, toList)
import qualified Data.Text as T
import qualified Data.Text.IO as T (readFile)


{-# ANN helperSettings ("HLint: ignore Use ||"        :: String) #-}
{-# ANN module         ("HLint: ignore Use camelCase" :: String) #-}


-----


patternMatchFail :: T.Text -> [T.Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Cmds.Pla"


-----


logNotice :: T.Text -> T.Text -> MudStack ()
logNotice = L.logNotice "Mud.Cmds.Pla"


logPla :: T.Text -> Id -> T.Text -> MudStack ()
logPla = L.logPla "Mud.Cmds.Pla"


logPlaExec :: CmdName -> Id -> MudStack ()
logPlaExec = L.logPlaExec "Mud.Cmds.Pla"


logPlaExecArgs :: CmdName -> Args -> Id -> MudStack ()
logPlaExecArgs = L.logPlaExecArgs "Mud.Cmds.Pla"


logPlaOut :: T.Text -> Id -> [T.Text] -> MudStack ()
logPlaOut = L.logPlaOut "Mud.Cmds.Pla"


-- ==================================================


plaCmds :: [Cmd]
plaCmds = sort $ regularCmds ++ priorityAbbrevCmds ++ expCmds


regularCmds :: [Cmd]
regularCmds = map (uncurry3 mkRegularCmd)
    [ ("?",          plaDispCmdList,  "Display or search this command list.")
    , ("about",      about,           "About CurryMUD.")
    , ("admin",      admin,           "Send a message to an administrator.")
    , ("d",          go "d",          "Go down.")
    , ("e",          go "e",          "Go east.")
    , ("equip",      equip,           "Display your readied equipment, or examine one or more items in your readied \
                                      \equipment.")
    , ("expressive", expCmdList,      "Display or search a list of available expressive commands and their results.")
    , ("i",          inv,             "Display your inventory, or examine one or more items in your inventory.")
    , ("l",          look,            "Display a description of your current location, or examine one or more items in \
                                      \your current location.")
    , ("n",          go "n",          "Go north.")
    , ("ne",         go "ne",         "Go northeast.")
    , ("nw",         go "nw",         "Go northwest.")
    , ("qui",        quitCan'tAbbrev, "")
    , ("quit",       quit,            "Quit playing CurryMUD.")
    , ("remove",     remove,          "Remove one or more items from a container.")
    , ("s",          go "s",          "Go south.")
    , ("se",         go "se",         "Go southeast.")
    , ("set",        setAction,       "View or change settings.")
    , ("sw",         go "sw",         "Go southwest.")
    , ("take",       getAction,       "Pick up one or more items.")
    , ("typo",       typo,            "Report a typo.")
    , ("u",          go "u",          "Go up.")
    , ("uptime",     uptime,          "Display how long CurryMUD has been running.")
    , ("w",          go "w",          "Go west.")
    , ("whoadmin",   whoAdmin,        "Display a list of the administrators who are currently logged in.")
    , ("whoami",     whoAmI,          "Confirm your name, sex, and race.") ]


mkRegularCmd :: CmdFullName -> Action -> CmdDesc -> Cmd
mkRegularCmd cfn act cd = Cmd { cmdName           = cfn
                              , cmdPriorityAbbrev = Nothing
                              , cmdFullName       = cfn
                              , action            = act
                              , cmdDesc           = cd }


-- TODO: "wh" should be "who".
priorityAbbrevCmds :: [Cmd]
priorityAbbrevCmds = concatMap (uncurry4 mkPriorityAbbrevCmd)
    [ ("bug",     "b",  bug,        "Report a bug.")
    , ("clear",   "c",  clear,      "Clear the screen.")
    , ("color",   "co", color,      "Perform a color test.")
    , ("drop",    "dr", dropAction, "Drop one or more items.")
    , ("emote",   "em", emote,      "Freely describe an action.")
    , ("exits",   "ex", exits,      "Display obvious exits.")
    , ("get",     "g",  getAction,  "Pick up one or more items.")
    , ("help",    "h",  help,       "Get help on one or more commands or topics.")
    , ("intro",   "in", intro,      "Introduce yourself.")
    , ("motd",    "m",  motd,       "Display the message of the day.")
    , ("put",     "p",  putAction,  "Put one or more items into a container.")
    , ("ready",   "r",  ready,      "Ready one or more items.")
    , ("say",     "sa", say,        "Say something out loud.")
    , ("unready", "un", unready,    "Unready one or more items.") ]


mkPriorityAbbrevCmd :: CmdFullName -> CmdPriorityAbbrevTxt -> Action -> CmdDesc -> [Cmd]
mkPriorityAbbrevCmd cfn cpat act cd = unfoldr helper (T.init cfn) ++ [ Cmd { cmdName           = cfn
                                                                           , cmdPriorityAbbrev = Just cpat
                                                                           , cmdFullName       = cfn
                                                                           , action            = act
                                                                           , cmdDesc           = cd } ]
  where
    helper ""                      = Nothing
    helper abbrev | abbrev == cpat = Just (mkExplicitAbbrevCmd, "")
                  | otherwise      = Just (mkExplicitAbbrevCmd, T.init abbrev)
      where
        mkExplicitAbbrevCmd = Cmd { cmdName           = abbrev
                                  , cmdPriorityAbbrev = Nothing
                                  , cmdFullName       = cfn
                                  , action            = act
                                  , cmdDesc           = "" }


-----


about :: Action
about (NoArgs i mq cols) = do
    helper |$| try >=> eitherRet ((sendGenericErrorMsg mq cols >>) . fileIOExHandler "about")
    logPlaExec "about" i
  where
    helper = multiWrapSend mq cols =<< [ T.lines cont | cont <- liftIO . T.readFile $ aboutFile ]
about p = withoutArgs about p


-----


admin :: Action
admin p@AdviseNoArgs = advise p ["admin"] advice
  where
    advice = T.concat [ "Please specify the name of an administrator followed by a message, as in "
                      , quoteColor
                      , dblQuote "admin jason are you available? I need your assistance"
                      , dfltColor
                      , "." ]
admin p@(AdviseOneArg a) = advise p ["admin"] advice
  where
    advice = T.concat [ "Please also provide a message to send, as in "
                      , quoteColor
                      , dblQuote $ "admin " <> a <> " are you available? I need your assistance"
                      , dfltColor
                      , "." ]
admin (MsgWithTarget i mq cols target msg) = getState >>= \ms ->
    let adminIdSings = [ ais | ais@(ai, _) <- mkAdminIdSingList ms
                             , let p = getPla ai ms, isLoggedIn p, not . getPlaFlag IsIncognito $ p ]
        s            = getSing i ms
        notFound     = wrapSend mq cols $ "No administrator by the name of " <> dblQuote target <> " is currently \
                                          \logged in."
        found (adminId, _        ) | adminId == i = wrapSend mq cols "You talk to yourself."
        found (adminId, adminSing) | adminMq <- getMsgQueue adminId ms, adminCols <- getColumns adminId ms = do
            wrapSend mq      cols      . T.concat $ [ "You send ",              adminSing, ": ", dblQuote msg ]
            wrapSend adminMq adminCols . T.concat $ [ bracketQuote s, " ", adminMsgColor, msg, dfltColor      ]
            logPla    "admin" i        . T.concat $ [     "sent message to ",   adminSing, ": ", dblQuote msg ]
            logPla    "admin" adminId  . T.concat $ [ "received message from ", s,         ": ", dblQuote msg ]
            logNotice "admin"          . T.concat $ [ s, " sent message to ",   adminSing, ": ", dblQuote msg ]
    in maybe notFound found . findFullNameForAbbrev target $ adminIdSings
admin p = patternMatchFail "admin" [ showText p ]


-----


bug :: Action
bug p@AdviseNoArgs = advise p ["bug"] advice
  where
    advice = T.concat [ "Please describe the bug you've found, as in "
                      , quoteColor
                      , dblQuote "bug I've fallen and I can't get up!"
                      , dfltColor
                      , "." ]
bug p = bugTypoLogger p BugLog


-----


clear :: Action
clear (NoArgs' i mq) = (send mq . T.pack $ clearScreenCode) >> logPlaExec "clear" i
clear p              = withoutArgs clear p


-----


color :: Action
color (NoArgs' i mq) = (send mq . nl . T.concat $ msg) >> logPlaExec "color" i
  where
    msg = [ nl . T.concat $ [ mkColorDesc fg bg, ansi, " CurryMUD ", dfltColor ]
          | fgc <- colors, bgc <- colors, fgc /= bgc
          , let fg = (Dull, fgc), let bg = (Dull, bgc), let ansi = mkColorANSI fg bg ] ++ other
    mkColorDesc (mkColorName -> fg) (mkColorName -> bg) = fg <> "on " <> bg
    mkColorName                                         = pad 8 . showText . snd
    other = [ nl . T.concat $ [ pad 19 "Blinking",   blinkANSI,     " CurryMUD ", noBlinkANSI     ]
            , nl . T.concat $ [ pad 19 "Underlined", underlineANSI, " CurryMUD ", noUnderlineANSI ] ]
color p = withoutArgs color p


-----


dropAction :: Action
dropAction p@AdviseNoArgs = advise p ["drop"] advice
  where
    advice = T.concat [ "Please specify one or more items to drop, as in "
                      , quoteColor
                      , dblQuote "drop sword"
                      , dfltColor
                      , "." ]
dropAction (LowerNub' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "drop" i $ logMsgs)
  where
    helper ms =
        let invCoins              = getInvCoins i ms
            d                     = mkStdDesig  i ms DoCap
            ri                    = getRmId     i ms
            (eiss, ecs)           = uncurry (resolvePCInvCoins i ms as) invCoins
            (ms',  bs,  logMsgs ) = foldl' (helperDropEitherInv      i d      i ri) (ms,  [], []     ) eiss
            (ms'', bs', logMsgs') = foldl' (helperGetDropEitherCoins i d Drop i ri) (ms', bs, logMsgs) ecs
        in if notEmpty invCoins
          then (ms'', (bs',                                 logMsgs'))
          else (ms,   (mkBroadcast i dudeYourHandsAreEmpty, []      ))
dropAction p = patternMatchFail "dropAction" [ showText p ]


-----


emote :: Action
emote p@AdviseNoArgs = advise p ["emote"] advice
  where
    advice = T.concat [ "Please provide a description of an action, as in "
                      , quoteColor
                      , dblQuote "emote laughs with relief as tears roll down her face"
                      , dfltColor
                      , "." ]
emote p@(ActionParams { plaId, args })
  | any (`elem` args) [ enc, enc <> "'s" ] = getState >>= \ms ->
      let d@(stdPCEntSing -> Just s) = mkStdDesig plaId ms DoCap
          toSelfMsg                  = bracketQuote . T.replace enc s . formatMsgArgs $ args
          toSelfBroadcast            = mkBroadcast plaId . nlnl $ toSelfMsg
          toOthersMsg | c == emoteNameChar = T.concat [ serialize d, T.tail h, " ", T.unwords . tail $ args ]
                      | otherwise          = capitalizeMsg . T.unwords $ args
          toOthersMsg'      = T.replace enc (serialize d { shouldCap = Don'tCap }) . punctuateMsg $ toOthersMsg
          toOthersBroadcast = [(nlnl . bracketQuote $ toOthersMsg', plaId `delete` pcIds d)]
      in bcastSelfOthers plaId ms toSelfBroadcast toOthersBroadcast >> logPlaOut "emote" plaId [toSelfMsg]
  | any (enc `T.isInfixOf`) args = advise p ["emote"] advice
  | otherwise = getState >>= \ms ->
    let d@(stdPCEntSing -> Just s) = mkStdDesig plaId ms DoCap
        msg                        = punctuateMsg . T.unwords $ args
        toSelfMsg                  = bracketQuote $ s <> " " <> msg
        toSelfBroadcast            = mkBroadcast plaId . nlnl $ toSelfMsg
        toOthersMsg                = bracketQuote $ serialize d <> " " <> msg
        toOthersBroadcast          = [(nlnl toOthersMsg, plaId `delete` pcIds d)]
    in bcastSelfOthers plaId ms toSelfBroadcast toOthersBroadcast >> logPlaOut "emote" plaId [toSelfMsg]
  where
    h@(T.head -> c) = head args
    enc             = T.singleton emoteNameChar
    advice          = T.concat [ dblQuote enc
                               , " must either be used alone, or with a "
                               , dblQuote "'s"
                               , " suffix (to create a possessive noun), as in "
                               , quoteColor
                               , dblQuote $ "emote shielding her eyes from the sun, " <> enc <> " looks out across the \
                                            \plains"
                               , dfltColor
                               , ", or "
                               , quoteColor
                               , dblQuote $ "emote " <> enc <> "'s leg twitches involuntarily as she laughs with gusto"
                               , dfltColor
                               , "." ]


-----


equip :: Action
equip (NoArgs i mq cols)      = getState >>= \ms -> send mq . nl . mkEqDesc i cols ms i (getSing i ms) $ PCType
equip (LowerNub i mq cols as) = getState >>= \ms ->
    let em@(M.elems -> is) = getEqMap i ms in send mq $ if not . M.null $ em
      then let (gecrs, miss, rcs)                    = resolveEntCoinNames i ms as is mempty
               eiss                                  = zipWith (curry procGecrMisPCEq) gecrs miss
               invDesc                               = foldl' helperEitherInv "" eiss
               helperEitherInv acc (Left  msg)       = (acc <>) . wrapUnlinesNl cols $ msg
               helperEitherInv acc (Right targetIds) = nl $ acc <> mkEntDescs i cols ms targetIds
               coinsDesc                             = rcs |!| wrapUnlinesNl cols "You don't have any coins among your \
                                                                                  \readied equipment."
           in invDesc <> coinsDesc
      else wrapUnlinesNl cols dudeYou'reNaked
equip p = patternMatchFail "equip" [ showText p ]


-----


exits :: Action
exits (NoArgs i mq cols) = getState >>= \ms ->
    (send mq . nl . mkExitsSummary cols . getPCRm i $ ms) >> logPlaExec "exits" i
exits p = withoutArgs exits p


-----


expCmdList :: Action
expCmdList (NoArgs i mq cols) =
    (pager i mq . concatMap (wrapIndent (succ maxCmdLen) cols) $ mkExpCmdListTxt) >> logPlaExecArgs "expressive" [] i
expCmdList p@(ActionParams { plaId, args }) =
    dispMatches p (succ maxCmdLen) mkExpCmdListTxt >> logPlaExecArgs "expressive" args plaId


mkExpCmdListTxt :: [T.Text]
mkExpCmdListTxt =
    let cmdNames       = [ cmdName cmd | cmd <- plaCmds ]
        styledCmdNames = styleAbbrevs Don'tBracket cmdNames
    in concatMap mkExpCmdTxt [ (styled, head matches) | (cn, styled) <- zip cmdNames styledCmdNames
                                                      , let matches = findMatches cn
                                                      , length matches == 1 ]
  where
    findMatches cn = S.toList . S.filter (\(ExpCmd ecn _) -> ecn == cn) $ expCmdSet
    mkExpCmdTxt (styled, ExpCmd ecn ect) = case ect of
      (NoTarget  toSelf _  ) -> [ paddedName <> mkInitialTxt  ecn <> toSelf ]
      (HasTarget toSelf _ _) -> [ paddedName <> mkInitialTxt (ecn <> " hanako") <> T.replace "@" "Hanako" toSelf ]
      (Versatile toSelf _ toSelfWithTarget _ _) -> [ paddedName <> mkInitialTxt ecn <> toSelf
                                                   , T.replicate (succ maxCmdLen) (T.singleton indentFiller) <>
                                                     mkInitialTxt (ecn <> " hanako")                         <>
                                                     T.replace "@" "Hanako" toSelfWithTarget ]
      where
        paddedName         = pad (succ maxCmdLen) styled
        mkInitialTxt input = T.concat [ quoteColor
                                      , dblQuote input
                                      , dfltColor
                                      , " "
                                      , arrowColor
                                      , "->"
                                      , dfltColor
                                      , " " ]


-----


getAction :: Action
getAction p@AdviseNoArgs = advise p ["get"] advice
  where
    advice = T.concat [ "Please specify one or more items to pick up, as in "
                      , quoteColor
                      , dblQuote "get sword"
                      , dfltColor
                      , "." ]
getAction (Lower _ mq cols as) | length as >= 3, (head . tail .reverse $ as) == "from" =
    wrapSend mq cols . T.concat $ [ hintANSI
                                  , "Hint:"
                                  , noHintANSI
                                  , " it appears that you want to remove an object from a container. In that case, \
                                    \please use the "
                                  , dblQuote "remove"
                                  , " command. For example, to remove a ring from your sack, type "
                                  , quoteColor
                                  , dblQuote "remove ring sack"
                                  , dfltColor
                                  , "." ]
getAction (LowerNub' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "get" i $ logMsgs)
  where
    helper ms =
        let ri                    = getRmId i ms
            invCoins              = first (i `delete`) . getNonIncogInvCoins ri $ ms
            d                     = mkStdDesig i ms DoCap
            (eiss, ecs)           = uncurry (resolveRmInvCoins i ms as) invCoins
            (ms',  bs,  logMsgs ) = foldl' (helperGetEitherInv       i d     ri i) (ms,  [], []     ) eiss
            (ms'', bs', logMsgs') = foldl' (helperGetDropEitherCoins i d Get ri i) (ms', bs, logMsgs) ecs
        in if notEmpty invCoins
          then (ms'', (bs',                                                     logMsgs'))
          else (ms,   (mkBroadcast i "You don't see anything here to pick up.", []      ))
getAction p = patternMatchFail "getAction" [ showText p ]


-----


go :: T.Text -> Action
go dir p@(ActionParams { args = [] }) = goDispatcher p { args = [dir]      }
go dir p@(ActionParams { args      }) = goDispatcher p { args = dir : args }


goDispatcher :: Action
goDispatcher   (ActionParams { args = [] }) = return ()
goDispatcher p@(Lower i mq cols as)         = mapM_ (tryMove i mq cols p { args = [] }) as
goDispatcher p                              = patternMatchFail "goDispatcher" [ showText p ]


tryMove :: Id -> MsgQueue -> Cols -> ActionParams -> T.Text -> MudStack ()
tryMove i mq cols p dir = helper |$| modifyState >=> \case
  Left  msg          -> wrapSend mq cols msg
  Right (bs, logMsg) -> look p >> bcastIfNotIncog i bs >> logPla "tryMove" i logMsg
  where
    helper ms =
        let originId = getRmId i ms
            originRm = getRm originId ms
        in case findExit originRm dir of
          Nothing -> (ms, Left sorry)
          Just (linkTxt, destId, maybeOriginMsg, maybeDestMsg) ->
            let originDesig = mkStdDesig i ms DoCap
                s           = fromJust . stdPCEntSing $ originDesig
                originPCIds = i `delete` pcIds originDesig
                destPCIds   = findPCIds ms $ ms^.invTbl.ind destId
                ms'         = ms & pcTbl .ind i.rmId   .~ destId
                                 & invTbl.ind originId %~ (i `delete`)
                                 & invTbl.ind destId   %~ (sortInv ms . (++ [i]))
                msgAtOrigin = nlnl $ case maybeOriginMsg of
                                Nothing  -> T.concat [ serialize originDesig, " ", verb, " ", expandLinkName dir, "." ]
                                Just msg -> T.replace "%" (serialize originDesig) msg
                msgAtDest   = let destDesig = mkSerializedNonStdDesig i ms s A DoCap in nlnl $ case maybeDestMsg of
                                Nothing  -> T.concat [ destDesig, " arrives from ", expandOppLinkName dir, "." ]
                                Just msg -> T.replace "%" destDesig msg
                logMsg      = T.concat [ "moved "
                                       , linkTxt
                                       , " from room "
                                       , showRm originId originRm
                                       , " to room "
                                       , showRm destId . getRm destId $ ms
                                       , "." ]
            in (ms', Right ([ (msgAtOrigin, originPCIds), (msgAtDest, destPCIds) ], logMsg))
    sorry = dir `elem` stdLinkNames ? "You can't go that way." :? dblQuote dir <> " is not a valid exit."
    verb
      | dir == "u"              = "goes"
      | dir == "d"              = "heads"
      | dir `elem` stdLinkNames = "leaves"
      | otherwise               = "enters"
    showRm (showText -> ri) (views rmName parensQuote -> rn) = ri <> " " <> rn


findExit :: Rm -> LinkName -> Maybe (T.Text, Id, Maybe T.Text, Maybe T.Text)
findExit (view rmLinks -> rls) ln =
    case [ (showLink rl, getDestId rl, getOriginMsg rl, getDestMsg rl) | rl <- rls, isValid rl ] of
      [] -> Nothing
      xs -> Just . head $ xs
  where
    isValid      StdLink    { .. } = ln == linkDirToCmdName _linkDir
    isValid      NonStdLink { .. } = ln `T.isPrefixOf` _linkName
    showLink     StdLink    { .. } = showText _linkDir
    showLink     NonStdLink { .. } = _linkName
    getDestId    StdLink    { .. } = _stdDestId
    getDestId    NonStdLink { .. } = _nonStdDestId
    getOriginMsg NonStdLink { .. } = Just _originMsg
    getOriginMsg _                 = Nothing
    getDestMsg   NonStdLink { .. } = Just _destMsg
    getDestMsg   _                 = Nothing


expandLinkName :: T.Text -> T.Text
expandLinkName "n"  = "north"
expandLinkName "ne" = "northeast"
expandLinkName "e"  = "east"
expandLinkName "se" = "southeast"
expandLinkName "s"  = "south"
expandLinkName "sw" = "southwest"
expandLinkName "w"  = "west"
expandLinkName "nw" = "northwest"
expandLinkName "u"  = "up"
expandLinkName "d"  = "down"
expandLinkName x    = patternMatchFail "expandLinkName" [x]


expandOppLinkName :: T.Text -> T.Text
expandOppLinkName "n"  = "the south"
expandOppLinkName "ne" = "the southwest"
expandOppLinkName "e"  = "the west"
expandOppLinkName "se" = "the northwest"
expandOppLinkName "s"  = "the north"
expandOppLinkName "sw" = "the northeast"
expandOppLinkName "w"  = "the east"
expandOppLinkName "nw" = "the southeast"
expandOppLinkName "u"  = "below"
expandOppLinkName "d"  = "above"
expandOppLinkName x    = patternMatchFail "expandOppLinkName" [x]


-----


help :: Action
help (NoArgs i mq cols) = (liftIO . T.readFile $ helpDir </> "root") |$| try >=> either handler helper
  where
    handler e = fileIOExHandler "help" e >> wrapSend mq cols "Unfortunately, the root help file could not be retrieved."
    helper rootHelpTxt = (getPlaFlag IsAdmin . getPla i <$> getState) >>= \isAdmin -> do
        (sortBy (compare `on` helpName) -> hs) <- liftIO . mkHelpData $ isAdmin
        let zipped                 = zip (styleAbbrevs Don'tBracket [ helpName h | h <- hs ]) hs
            (cmdNames, topicNames) = partition (isCmdHelp . snd) zipped & both %~ (formatHelpNames . mkHelpNames)
            helpTxt                = T.concat [ nl rootHelpTxt
                                              , nl "Help is available on the following commands:"
                                              , nl cmdNames
                                              , nl "Help is available on the following topics:"
                                              , topicNames
                                              , isAdmin |?| footnote ]
        (pager i mq . parseHelpTxt cols $ helpTxt) >> logPla "help" i "read root help file."
    mkHelpNames zipped    = [ pad padding . (styled <>) $ isAdminHelp h |?| asterisk | (styled, h) <- zipped ]
    padding               = maxHelpTopicLen + 2
    asterisk              = asteriskColor <> "*" <> dfltColor
    formatHelpNames names = let wordsPerLine = cols `div` padding
                            in T.unlines . map T.concat . chunksOf wordsPerLine $ names
    footnote              = nlPrefix $ asterisk <> " indicates help that is available only to administrators."
help (LowerNub i mq cols as) = (getPlaFlag IsAdmin . getPla i <$> getState) >>= liftIO . mkHelpData >>= \hs -> do
    (map (parseHelpTxt cols) -> helpTxts, dropBlanks -> hns) <- unzip <$> forM as (getHelpByName cols hs)
    pager i mq . intercalate [ "", mkDividerTxt cols, "" ] $ helpTxts
    unless (null hns) . logPla "help" i . ("read help on: " <>) . T.intercalate ", " $ hns
help p = patternMatchFail "help" [ showText p ]


mkHelpData :: Bool -> IO [Help]
mkHelpData isAdmin = helpDirs |$| mapM getHelpDirectoryContents >=> \[ plaHelpCmdNames
                                                                     , plaHelpTopicNames
                                                                     , adminHelpCmdNames
                                                                     , adminHelpTopicNames ] -> do
    let phcs = [ Help { helpName     = T.pack phcn
                      , helpFilePath = plaHelpCmdsDir     </> phcn
                      , isCmdHelp    = True
                      , isAdminHelp  = False } | phcn <- plaHelpCmdNames     ]
        phts = [ Help { helpName     = T.pack phtn
                      , helpFilePath = plaHelpTopicsDir   </> phtn
                      , isCmdHelp    = False
                      , isAdminHelp  = False } | phtn <- plaHelpTopicNames   ]
        ahcs = [ Help { helpName     = T.pack $ adminCmdChar : whcn
                      , helpFilePath = adminHelpCmdsDir   </> whcn
                      , isCmdHelp    = True
                      , isAdminHelp  = True }  | whcn <- adminHelpCmdNames   ]
        ahts = [ Help { helpName     = T.pack whtn
                      , helpFilePath = adminHelpTopicsDir </> whtn
                      , isCmdHelp    = False
                      , isAdminHelp  = True }  | whtn <- adminHelpTopicNames ]
    return $ phcs ++ phts ++ (guard isAdmin >> ahcs ++ ahts)
  where
    helpDirs                     = [ plaHelpCmdsDir, plaHelpTopicsDir, adminHelpCmdsDir, adminHelpTopicsDir ]
    getHelpDirectoryContents dir = dropIrrelevantFilenames . sort <$> getDirectoryContents dir


parseHelpTxt :: Cols -> T.Text -> [T.Text]
parseHelpTxt cols = concat . wrapLines cols . T.lines . parseTokens


getHelpByName :: Cols -> [Help] -> HelpName -> MudStack (T.Text, T.Text)
getHelpByName cols hs name = maybe sorry found . findFullNameForAbbrev name $ [ (h, helpName h) | h <- hs ]
  where
    sorry                                      = return ("No help is available on " <> dblQuote name <> ".", "")
    found (helpFilePath -> hf, dblQuote -> hn) = (,) <$> readHelpFile hf hn <*> return hn
    readHelpFile hf hn                         = (liftIO . T.readFile $ hf) |$| try >=> eitherRet handler
      where
        handler e = do
            fileIOExHandler "getHelpByName readHelpFile" e
            return . wrapUnlines cols $ "Unfortunately, the " <> hn <> " help file could not be retrieved."


-----


intro :: Action
intro (NoArgs i mq cols) = getState >>= \ms -> let intros = getIntroduced i ms in if null intros
  then let introsTxt = "No one has introduced themselves to you yet." in
      wrapSend mq cols introsTxt >> logPlaOut "intro" i [introsTxt]
  else let introsTxt = T.intercalate ", " intros in
      multiWrapSend mq cols [ "You know the following names:", introsTxt ] >> logPlaOut "intro" i [introsTxt]
intro (LowerNub' i as) = helper |$| modifyState >=> \(map fromClassifiedBroadcast . sort -> bs, logMsgs) ->
    bcastIfNotIncog i bs >> (unless (null logMsgs) . logPlaOut "intro" i $ logMsgs)
  where
    helper ms =
        let invCoins@(first (i `delete`) -> invCoins') = getPCRmNonIncogInvCoins i ms
            (eiss, ecs)          = uncurry (resolveRmInvCoins i ms as) invCoins'
            (pt, cbs,  logMsgs ) = foldl' (helperIntroEitherInv ms (fst invCoins)) (ms^.pcTbl, [],  []     ) eiss
            (    cbs', logMsgs') = foldl' helperIntroEitherCoins                   (           cbs, logMsgs) ecs
        in if notEmpty invCoins'
          then (ms & pcTbl .~ pt, (cbs', logMsgs'))
          else (ms, (mkNTBroadcast i . nlnl $ "You don't see anyone here to introduce yourself to.", []))
    helperIntroEitherInv _  _   a (Left msg       ) = T.null msg ? a :? (a & _2 <>~ (mkNTBroadcast i . nlnl $ msg))
    helperIntroEitherInv ms ris a (Right targetIds) = foldl' tryIntro a targetIds
      where
        tryIntro a'@(pt, _, _) targetId = let targetSing = getSing targetId ms in case getType targetId ms of
          PCType -> let s           = getSing i ms
                        targetDesig = serialize . mkStdDesig targetId ms $ Don'tCap
                        msg         = "You introduce yourself to " <> targetDesig <> "."
                        logMsg      = "Introduced to " <> targetSing <> "."
                        srcMsg      = nlnl msg
                        pis         = findPCIds ms ris
                        srcDesig    = StdDesig { stdPCEntSing = Nothing
                                               , shouldCap    = DoCap
                                               , pcEntName    = mkUnknownPCEntName i ms
                                               , pcId         = i
                                               , pcIds        = pis }
                        himHerself  = mkReflexPro . getSex i $ ms
                        targetMsg   = nlnl . T.concat $ [ serialize srcDesig
                                                        , " introduces "
                                                        , himHerself
                                                        , " to you as "
                                                        , knownNameColor
                                                        , s
                                                        , dfltColor
                                                        , "." ]
                        othersMsg   = nlnl . T.concat $ [ serialize srcDesig { stdPCEntSing = Just s }
                                                        , " introduces "
                                                        , himHerself
                                                        , " to "
                                                        , targetDesig
                                                        , "." ]
                        cbs         = [ NonTargetBroadcast (srcMsg,    [i]                   )
                                      , TargetBroadcast    (targetMsg, [targetId]            )
                                      , NonTargetBroadcast (othersMsg, pis \\ [ i, targetId ]) ]
                    in if s `elem` pt^.ind targetId.introduced
                      then let sorry = nlnl $ "You've already introduced yourself to " <> targetDesig <> "."
                           in a' & _2 <>~ mkNTBroadcast i sorry
                      else a' & _1.ind targetId.introduced %~ (sort . (s :)) & _2 <>~ cbs & _3 <>~ [logMsg]
          _      -> let msg = "You can't introduce yourself to " <> theOnLower targetSing <> "."
                        b   = head . mkNTBroadcast i . nlnl $ msg
                    in a' & _2 %~ (`appendIfUnique` b)
    helperIntroEitherCoins a (Left  msgs) = a & _1 <>~ (mkNTBroadcast i . T.concat $ [ nlnl msg | msg <- msgs ])
    helperIntroEitherCoins a (Right {}  ) =
        let cb = head . mkNTBroadcast i . nlnl $ "You can't introduce yourself to a coin."
        in first (`appendIfUnique` cb) a
    fromClassifiedBroadcast (TargetBroadcast    b) = b
    fromClassifiedBroadcast (NonTargetBroadcast b) = b
intro p = patternMatchFail "intro" [ showText p ]


-----


inv :: Action
inv (NoArgs i mq cols)      = getState >>= \ms@(getSing i -> s) -> send mq . nl . mkInvCoinsDesc i cols ms i $ s
inv (LowerNub i mq cols as) = getState >>= \ms ->
    let invCoins    = getInvCoins i ms
        (eiss, ecs) = uncurry (resolvePCInvCoins i ms as) invCoins
        invDesc     = foldl' (helperEitherInv ms) "" eiss
        coinsDesc   = foldl' helperEitherCoins    "" ecs
    in send mq $ if notEmpty invCoins
      then invDesc <> coinsDesc
      else wrapUnlinesNl cols dudeYourHandsAreEmpty
  where
    helperEitherInv _  acc (Left  msg ) = (acc <>) . wrapUnlinesNl cols $ msg
    helperEitherInv ms acc (Right is  ) = nl $ acc <> mkEntDescs i cols ms is
    helperEitherCoins  acc (Left  msgs) = (acc <>) . multiWrapNl cols . intersperse "" $ msgs
    helperEitherCoins  acc (Right c   ) = nl $ acc <> mkCoinsDesc cols c
inv p = patternMatchFail "inv" [ showText p ]


-----


look :: Action
look (NoArgs i mq cols) = getState >>= \ms ->
    let ri     = getRmId i  ms
        r      = getRm   ri ms
        top    = multiWrap cols [ T.concat [ underlineANSI, " ", r^.rmName, " ", noUnderlineANSI ], r^.rmDesc ]
        bottom = [ mkExitsSummary cols r, mkRmInvCoinsDesc i cols ms ri ]
    in send mq . nl . T.concat $ top : bottom
look (LowerNub i mq cols as) = helper |$| modifyState >=> \(ms, msg, bs, maybeTargetDesigs) -> do
    send mq msg
    unless (getPlaFlag IsIncognito . getPla i $ ms) . bcast $ bs
    let logHelper targetDesigs | targetSings <- [ fromJust . stdPCEntSing $ targetDesig | targetDesig <- targetDesigs ]
                               = logPla "look" i $ "looked at: " <> T.intercalate ", " targetSings <> "."
    maybeVoid logHelper maybeTargetDesigs
  where
    helper ms = let invCoins = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms in if notEmpty invCoins
        then let (eiss, ecs)  = uncurry (resolveRmInvCoins i ms as) invCoins
                 invDesc      = foldl' (helperLookEitherInv ms) "" eiss
                 coinsDesc    = foldl' helperLookEitherCoins    "" ecs
                 (pt, msg)    = firstLook i cols (ms^.plaTbl, invDesc <> coinsDesc)
                 selfDesig    = mkStdDesig i ms DoCap
                 selfDesig'   = serialize selfDesig
                 pis          = i `delete` pcIds selfDesig
                 targetDesigs = [ mkStdDesig targetId ms Don'tCap | targetId <- extractPCIdsFromEiss ms eiss ]
                 mkBroadcastsForTarget targetDesig acc =
                     let targetId = pcId targetDesig
                         toTarget = (nlnl $ selfDesig' <> " looks at you.", [targetId])
                         toOthers = ( nlnl . T.concat $ [ selfDesig', " looks at ", serialize targetDesig, "." ]
                                    , targetId `delete` pis)
                     in toTarget : toOthers : acc
                 ms' = ms & plaTbl .~ pt
             in (ms', (ms', msg, foldr mkBroadcastsForTarget [] targetDesigs, targetDesigs |!| Just targetDesigs))
        else let msg        = wrapUnlinesNl cols "You don't see anything here to look at."
                 (pt, msg') = firstLook i cols (ms^.plaTbl, msg)
                 ms'        = ms & plaTbl .~ pt
             in (ms', (ms', msg', [], Nothing))
    helperLookEitherInv _  acc (Left  msg ) = acc <> wrapUnlinesNl cols msg
    helperLookEitherInv ms acc (Right is  ) = nl $ acc <> mkEntDescs i cols ms is
    helperLookEitherCoins  acc (Left  msgs) = (acc <>) . multiWrapNl cols . intersperse "" $ msgs
    helperLookEitherCoins  acc (Right c   ) = nl $ acc <> mkCoinsDesc cols c
look p = patternMatchFail "look" [ showText p ]


mkRmInvCoinsDesc :: Id -> Cols -> MudState -> Id -> T.Text
mkRmInvCoinsDesc i cols ms ri =
    let (ris, c)            = first (i `delete`) . getNonIncogInvCoins ri $ ms
        (pcNcbs, otherNcbs) = splitPCsOthers . mkIsPC_StyledName_Count_BothList i ms $ ris
        pcDescs             = T.unlines . concatMap (wrapIndent 2 cols . mkPCDesc   ) $ pcNcbs
        otherDescs          = T.unlines . concatMap (wrapIndent 2 cols . mkOtherDesc) $ otherNcbs
    in (pcNcbs |!| pcDescs) <> (otherNcbs |!| otherDescs) <> (c |!| mkCoinsSummary cols c)
  where
    splitPCsOthers                       = (both %~ map snd) . span fst
    mkPCDesc    (en, c, (s, _)) | c == 1 = (<> " " <> en) $ if isKnownPCSing s
                                             then knownNameColor   <> s       <> dfltColor
                                             else unknownNameColor <> aOrAn s <> dfltColor
    mkPCDesc    (en, c, b     )          = T.concat [ unknownNameColor
                                                    , showText c
                                                    , " "
                                                    , mkPlurFromBoth b
                                                    , dfltColor
                                                    , " "
                                                    , en ]
    mkOtherDesc (en, c, (s, _)) | c == 1 = aOrAnOnLower s <> " " <> en
    mkOtherDesc (en, c, b     )          = T.concat [ showText c, " ", mkPlurFromBoth b, " ", en ]


mkIsPC_StyledName_Count_BothList :: Id -> MudState -> Inv -> [(Bool, (T.Text, Int, BothGramNos))]
mkIsPC_StyledName_Count_BothList i ms targetIds =
  let isPCs   =                        [ getType targetId ms == PCType   | targetId <- targetIds ]
      styleds = styleAbbrevs DoBracket [ getEffName        i ms targetId | targetId <- targetIds ]
      boths   =                        [ getEffBothGramNos i ms targetId | targetId <- targetIds ]
      counts  = mkCountList boths
  in nub . zip isPCs . zip3 styleds counts $ boths


firstLook :: Id -> Cols -> (PlaTbl, T.Text) -> (PlaTbl, T.Text)
firstLook i cols a@(pt, _) = if pt^.ind i.to (getPlaFlag IsNotFirstLook)
  then a
  else let msg = T.concat [ hintANSI
                          , "Hint:"
                          , noHintANSI
                          , " use the "
                          , dblQuote "l"
                          , " command to examine one or more items in your current location. To examine items in \
                            \your inventory, use the "
                          , dblQuote "i"
                          , " command "
                          , parensQuote $ "for example: " <> quoteColor <> dblQuote "i bread" <> dfltColor
                          , ". To examine items in your readied equipment, use the "
                          , dblQuote "equip"
                          , " command "
                          , parensQuote $ "for example: " <> quoteColor <> dblQuote "equip sword" <> dfltColor
                          , ". "
                          , quoteColor
                          , dblQuote "i"
                          , dfltColor
                          , " and "
                          , quoteColor
                          , dblQuote "equip"
                          , dfltColor
                          , " alone will list the items in your inventory and readied equipment, respectively." ]
       in a & _1.ind i %~ setPlaFlag IsNotFirstLook True & _2 <>~ wrapUnlinesNl cols msg


isKnownPCSing :: Sing -> Bool
isKnownPCSing s = case T.words s of [ "male",   _ ] -> False
                                    [ "female", _ ] -> False
                                    _               -> True


extractPCIdsFromEiss :: MudState -> [Either T.Text Inv] -> [Id]
extractPCIdsFromEiss ms = foldl' helper []
  where
    helper acc (Left  {})  = acc
    helper acc (Right is)  = acc ++ findPCIds ms is


-----


motd :: Action
motd (NoArgs i mq cols) = showMotd mq cols >> logPlaExec "motd" i
motd p                  = withoutArgs motd p


showMotd :: MsgQueue -> Cols -> MudStack ()
showMotd mq cols = send mq =<< helper
  where
    helper    = liftIO readMotd |$| try >=> eitherRet handler
    readMotd  = [ frame cols . multiWrap cols . T.lines . colorizeFileTxt motdColor $ cont
                | cont <- T.readFile motdFile ]
    handler e = do
        fileIOExHandler "showMotd" e
        return . wrapUnlinesNl cols $ "Unfortunately, the message of the day could not be retrieved."


-----


plaDispCmdList :: Action
plaDispCmdList p@(LowerNub' i as) = dispCmdList plaCmds p >> logPlaExecArgs "?" as i
plaDispCmdList p                  = patternMatchFail "plaDispCmdList" [ showText p ]


-----


putAction :: Action
putAction p@AdviseNoArgs = advise p ["put"] advice
  where
    advice = T.concat [ "Please specify one or more items you want to put followed by where you want to put them, as \
                        \in "
                      , quoteColor
                      , dblQuote "put doll sack"
                      , dfltColor
                      , "." ]
putAction p@(AdviseOneArg a) = advise p ["put"] advice
  where
    advice = T.concat [ "Please also specify where you want to put it, as in "
                      , quoteColor
                      , dblQuote $ "put " <> a <> " sack"
                      , dfltColor
                      , "." ]
putAction (Lower' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "put" i $ logMsgs)
  where
    helper ms = let (d, pcInvCoins, rmInvCoins, conName, argsWithoutCon) = mkPutRemoveBindings i ms as
                in if notEmpty pcInvCoins
                  then case T.uncons conName of
                    Just (c, not . T.null -> isn'tNull) | c == rmChar, isn'tNull -> if not . null . fst $ rmInvCoins
                      then shufflePut i ms d (T.tail conName) True argsWithoutCon rmInvCoins pcInvCoins procGecrMisRm
                      else (ms, (mkBroadcast i "You don't see any containers here.", []))
                    _ -> shufflePut i ms d conName False argsWithoutCon pcInvCoins pcInvCoins procGecrMisPCInv
                  else (ms, (mkBroadcast i dudeYourHandsAreEmpty, []))
putAction p = patternMatchFail "putAction" [ showText p ]


type CoinsWithCon = Coins
type PCInv        = Inv
type PCCoins      = Coins


shufflePut :: Id
           -> MudState
           -> PCDesig
           -> ConName
           -> IsConInRm
           -> Args
           -> (InvWithCon, CoinsWithCon)
           -> (PCInv, PCCoins)
           -> ((GetEntsCoinsRes, Maybe Inv) -> Either T.Text Inv)
           -> (MudState, ([Broadcast], [T.Text]))
shufflePut i ms d conName icir as invCoinsWithCon@(invWithCon, _) pcInvCoins f =
    let (conGecrs, conMiss, conRcs) = uncurry (resolveEntCoinNames i ms [conName]) invCoinsWithCon
    in if null conMiss && (not . null $ conRcs)
      then sorry "You can't put something inside a coin."
      else case f . head . zip conGecrs $ conMiss of
        Left  msg     -> sorry msg
        Right [conId] -> let conSing = getSing conId ms in if getType conId ms /= ConType
          then sorry $ theOnLowerCap conSing <> " isn't a container."
          else let (gecrs, miss, rcs)  = uncurry (resolveEntCoinNames i ms as) pcInvCoins
                   eiss                = zipWith (curry procGecrMisPCInv) gecrs miss
                   ecs                 = map procReconciledCoinsPCInv rcs
                   mnom                = mkMaybeNthOfM ms icir conId conSing invWithCon
                   (it, bs,  logMsgs ) = foldl' (helperPutRemEitherInv   i ms d Put mnom i conId conSing)
                                                (ms^.invTbl,   [], [])
                                                eiss
                   (ct, bs', logMsgs') = foldl' (helperPutRemEitherCoins i    d Put mnom i conId conSing)
                                                (ms^.coinsTbl, bs, logMsgs)
                                                ecs
               in (ms & invTbl .~ it & coinsTbl .~ ct, (bs', logMsgs'))
        Right {} -> sorry "You can only put things into one container at a time."
  where
    sorry msg = (ms, (mkBroadcast i msg, []))


-----


quit :: Action
quit (NoArgs' i mq)                        = logPlaExec "quit" i >> (liftIO . atomically . writeTQueue mq $ Quit)
quit ActionParams { plaMsgQueue, plaCols } = wrapSend plaMsgQueue plaCols msg
  where
    msg = T.concat [ "Type "
                   , quoteColor
                   , dblQuote "quit"
                   , dfltColor
                   , " with no arguments to quit CurryMUD." ]


handleEgress :: Id -> MudStack ()
handleEgress i = do
    informEgress
    helper |$| modifyState >=> \(s, bs, logMsgs) -> do
        closePlaLog i
        bcast bs
        bcastAdmins $ s <> " has left CurryMUD."
        forM_ logMsgs $ uncurry (logPla "handleEgress")
        logNotice "handleEgress" . T.concat $ [ "player ", showText i, " ", parensQuote s, " has left CurryMUD." ]
  where
    informEgress = getState >>= \ms -> let d = mkStdDesig i ms DoCap in
        unless (getRmId i ms == iWelcome) . bcastOthersInRm i $ nlnl (serialize d <> " slowly dissolves into \
                                                                                     \nothingness.")
    helper ms =
        let ri                 = getRmId i ms
            s                  = getSing i ms
            (ms', bs, logMsgs) = peepHelper ms s
            ms''               = if T.takeWhile (not . isDigit) s `elem` map showText [ Dwarf .. Vulpenoid ]
                                   then removeAdHoc i ms'
                                   else movePC ms' ri
        in (ms'', (s, bs, logMsgs))
    peepHelper ms s =
        let (peeperIds, peepingIds) = getPeepersPeeping i ms
            bs                      = [ (nlnl    . T.concat $ [ "You are no longer peeping "
                                                              , s
                                                              , " "
                                                              , parensQuote $ s <> " has disconnected"
                                                              , "." ], [peeperId]) | peeperId <- peeperIds ]
            logMsgs                 = [ (peeperId, T.concat   [ "no longer peeping "
                                                              , s
                                                              , " "
                                                              , parensQuote $ s <> " has disconnected"
                                                              , "." ]) | peeperId <- peeperIds ]
        in (ms & plaTbl %~ stopPeeping     peepingIds
               & plaTbl %~ stopBeingPeeped peeperIds
               & plaTbl.ind i.peeping .~ []
               & plaTbl.ind i.peepers .~ [], bs, logMsgs)
      where
        stopPeeping     peepingIds pt = let f peepedId ptAcc = ptAcc & ind peepedId.peepers %~ (i `delete`)
                                        in foldr f pt peepingIds
        stopBeingPeeped peeperIds  pt = let f peeperId ptAcc = ptAcc & ind peeperId.peeping %~ (i `delete`)
                                        in foldr f pt peeperIds
    movePC ms ri = ms & invTbl     .ind ri         %~ (i `delete`)
                      & invTbl     .ind iLoggedOut %~ (i :)
                      & msgQueueTbl.at  i          .~ Nothing
                      & pcTbl      .ind i.rmId     .~ iLoggedOut
                      & plaTbl     .ind i.lastRmId .~ Just ri


-----


quitCan'tAbbrev :: Action
quitCan'tAbbrev (NoArgs _ mq cols) =
    wrapSend mq cols . T.concat $ [ "The "
                                  , dblQuote "quit"
                                  , " command may not be abbreviated. Type "
                                  , dblQuote "quit"
                                  , " with no arguments to quit CurryMUD." ]
quitCan'tAbbrev p = withoutArgs quitCan'tAbbrev p


-----


ready :: Action
ready p@AdviseNoArgs = advise p ["ready"] advice
  where
    advice = T.concat [ "Please specify one or more items to ready, as in "
                      , quoteColor
                      , dblQuote "ready sword"
                      , dfltColor
                      , "." ]
ready (LowerNub' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "ready" i $ logMsgs)
  where
    helper ms =
        let invCoins@(is, _)          = getInvCoins i ms
            d                         = mkStdDesig  i ms DoCap
            (gecrs, mrols, miss, rcs) = resolveEntCoinNamesWithRols i ms as is mempty
            eiss                      = zipWith (curry procGecrMisReady) gecrs miss
            bs                        = rcs |!| mkBroadcast i "You can't ready coins."
            (et, it, bs', logMsgs)    = foldl' (helperReady i ms d) (ms^.eqTbl, ms^.invTbl, bs, []) . zip eiss $ mrols
        in if notEmpty invCoins
          then (ms & eqTbl .~ et & invTbl .~ it, (bs', logMsgs))
          else (ms, (mkBroadcast i dudeYourHandsAreEmpty, []))
ready p = patternMatchFail "ready" [ showText p ]


helperReady :: Id
            -> MudState
            -> PCDesig
            -> (EqTbl, InvTbl, [Broadcast], [T.Text])
            -> (Either T.Text Inv, Maybe RightOrLeft)
            -> (EqTbl, InvTbl, [Broadcast], [T.Text])
helperReady i ms d a (eis, mrol) = case eis of
  Left  (mkBroadcast i -> b) -> a & _3 <>~ b
  Right targetIds            -> foldl' (readyDispatcher i ms d mrol) a targetIds


readyDispatcher :: Id
                -> MudState
                -> PCDesig
                -> Maybe RightOrLeft
                -> (EqTbl, InvTbl, [Broadcast], [T.Text])
                -> Id
                -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyDispatcher i ms d mrol a targetId = let targetSing = getSing targetId ms in
    maybe (sorry targetSing) (\f -> f i ms d mrol a targetId targetSing) helper
  where
    helper = case getType targetId ms of
      ClothType -> Just readyCloth
      ConType   -> toMaybe (getIsCloth targetId ms) readyCloth
      WpnType   -> Just readyWpn
      ArmType   -> Just readyArm
      _         -> Nothing
    sorry targetSing = a & _3 <>~ mkBroadcast i ("You can't ready " <> aOrAn targetSing <> ".")


-- Readying clothing:


readyCloth :: Id
           -> MudState
           -> PCDesig
           -> Maybe RightOrLeft
           -> (EqTbl, InvTbl, [Broadcast], [T.Text])
           -> Id
           -> Sing
           -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyCloth i ms d mrol a@(et, _, _, _) clothId clothSing | em <- et ! i, cloth <- getCloth clothId ms =
    case maybe (getAvailClothSlot i ms cloth em) (getDesigClothSlot ms clothSing cloth em) mrol of
      Left  (mkBroadcast i -> b) -> a & _3 <>~ b
      Right slot                 -> moveReadiedItem i a slot clothId . mkReadyClothMsgs slot $ cloth
  where
    mkReadyClothMsgs (pp -> slot) = \case
      Earring  -> wearMsgs
      NoseRing -> putOnMsgs i d clothSing
      Necklace -> putOnMsgs i d clothSing
      Bracelet -> wearMsgs
      Ring     -> slideMsgs
      Backpack -> putOnMsgs i d clothSing
      _        -> donMsgs   i d clothSing
      where
        wearMsgs   = (   T.concat [ "You wear the ",  clothSing, " on your ", slot, "." ]
                     , ( T.concat [ serialize d, " wears ",  aOrAn clothSing, " on ", poss, " ", slot, "." ]
                       , otherPCIds ) )
        slideMsgs  = (   T.concat [ "You slide the ", clothSing, " on your ", slot, "." ]
                     , ( T.concat [ serialize d, " slides ", aOrAn clothSing, " on ", poss, " ", slot, "." ]
                       , otherPCIds) )
        poss       = mkPossPro . getSex i $ ms
        otherPCIds = i `delete` pcIds d


getAvailClothSlot :: Id -> MudState -> Cloth -> EqMap -> Either T.Text Slot
getAvailClothSlot i ms cloth em | sexy <- getSex i ms, h <- getHand i ms =
    maybe (Left . sorryFullClothSlots ms cloth $ em) Right $ case cloth of
      Earring  -> getEarringSlotForSex sexy `mplus` (getEarringSlotForSex . otherSex $ sexy)
      NoseRing -> findAvailSlot em noseRingSlots
      Necklace -> findAvailSlot em necklaceSlots
      Bracelet -> getBraceletSlotForHand h  `mplus` (getBraceletSlotForHand . otherHand $ h)
      Ring     -> getRingSlot sexy h
      _        -> maybeSingleSlot em . clothToSlot $ cloth
  where
    getEarringSlotForSex sexy = findAvailSlot em $ case sexy of
      Male   -> lEarringSlots
      Female -> rEarringSlots
      _      -> patternMatchFail "getAvailClothSlot getEarringSlotForSex"   [ showText sexy ]
    getBraceletSlotForHand h  = findAvailSlot em $ case h of
      RHand  -> lBraceletSlots
      LHand  -> rBraceletSlots
      _      -> patternMatchFail "getAvailClothSlot getBraceletSlotForHand" [ showText h    ]
    getRingSlot sexy h        = findAvailSlot em $ case sexy of
      Male    -> case h of
        RHand -> [ RingLRS, RingLIS, RingRRS, RingRIS, RingLMS, RingRMS, RingLPS, RingRPS ]
        LHand -> [ RingRRS, RingRIS, RingLRS, RingLIS, RingRMS, RingLMS, RingRPS, RingLPS ]
        _     -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText h ]
      Female  -> case h of
        RHand -> [ RingLRS, RingLIS, RingRRS, RingRIS, RingLPS, RingRPS, RingLMS, RingRMS ]
        LHand -> [ RingRRS, RingRIS, RingLRS, RingLIS, RingRPS, RingLPS, RingRMS, RingLMS ]
        _     -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText h    ]
      _       -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText sexy ]


otherSex :: Sex -> Sex
otherSex Male   = Female
otherSex Female = Male
otherSex NoSex  = NoSex


rEarringSlots, lEarringSlots, noseRingSlots, necklaceSlots, rBraceletSlots, lBraceletSlots :: [Slot]
rEarringSlots  = [ EarringR1S,    EarringR2S  ]
lEarringSlots  = [ EarringL1S,    EarringL2S  ]
noseRingSlots  = [ NoseRing1S,    NoseRing2S  ]
necklaceSlots  = [ Necklace1S  .. Necklace2S  ]
rBraceletSlots = [ BraceletR1S .. BraceletR3S ]
lBraceletSlots = [ BraceletL1S .. BraceletL3S ]


sorryFullClothSlots :: MudState -> Cloth -> EqMap -> T.Text
sorryFullClothSlots ms cloth@(pp -> cloth') em
  | cloth `elem` [ Earring .. Ring ]               = "You can't wear any more " <> cloth'               <> "s."
  | cloth `elem` [ Skirt, Dress, Backpack, Cloak ] = "You're already wearing "  <> aOrAn cloth'         <> "."
  | otherwise = let i = em M.! clothToSlot cloth in  "You're already wearing "  <> aOrAn (getSing i ms) <> "."


getDesigClothSlot :: MudState -> Sing -> Cloth -> EqMap -> RightOrLeft -> Either T.Text Slot
getDesigClothSlot ms clothSing cloth em rol
  | cloth `elem` [ NoseRing, Necklace ] ++ [ Shirt .. Cloak ] = Left sorryCan'tWearThere
  | isRingRol rol, cloth /= Ring                              = Left sorryCan'tWearThere
  | cloth == Ring, not . isRingRol $ rol                      = Left ringHelp
  | otherwise = case cloth of
    Earring  -> maybe (Left sorryEarring ) Right (findSlotFromList rEarringSlots  lEarringSlots )
    Bracelet -> maybe (Left sorryBracelet) Right (findSlotFromList rBraceletSlots lBraceletSlots)
    Ring     -> maybe (Right slotFromRol)
                      (Left . sorryRing slotFromRol)
                      (M.lookup slotFromRol em)
    _        -> patternMatchFail "getDesigClothSlot" [ showText cloth ]
  where
    sorryCan'tWearThere    = T.concat [ "You can't wear ", aOrAn clothSing, " on your ", pp rol, "." ]
    findSlotFromList rs ls = findAvailSlot em $ case rol of
      R -> rs
      L -> ls
      _ -> patternMatchFail "getDesigClothSlot findSlotFromList" [ showText rol ]
    getSlotFromList  rs ls = head $ case rol of
      R -> rs
      L -> ls
      _ -> patternMatchFail "getDesigClothSlot getSlotFromList"  [ showText rol ]
    sorryEarring     = sorryFullClothSlotsOneSide cloth . getSlotFromList rEarringSlots  $ lEarringSlots
    sorryBracelet    = sorryFullClothSlotsOneSide cloth . getSlotFromList rBraceletSlots $ lBraceletSlots
    slotFromRol      = fromRol rol :: Slot
    sorryRing slot i = T.concat [ "You're already wearing "
                                        , aOrAn . getSing i $ ms
                                        , " on your "
                                        , pp slot
                                        , "." ]


sorryFullClothSlotsOneSide :: Cloth -> Slot -> T.Text
sorryFullClothSlotsOneSide (pp -> c) (pp -> s) = T.concat [ "You can't wear any more "
                                                          , c
                                                          , "s on your "
                                                          , s
                                                          , "." ]


-- Readying weapons:


readyWpn :: Id
         -> MudState
         -> PCDesig
         -> Maybe RightOrLeft
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
         -> Id
         -> Sing
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyWpn i ms d mrol a@(et, _, _, _) wpnId wpnSing | em <- et ! i, wpn <- getWpn wpnId ms, sub <- wpn^.wpnSub =
    if not . isSlotAvail em $ BothHandsS
      then let b = mkBroadcast i "You're already wielding a two-handed weapon." in a & _3 <>~ b
      else case maybe (getAvailWpnSlot ms i em) (getDesigWpnSlot ms wpnSing em) mrol of
        Left  (mkBroadcast i -> b) -> a & _3 <>~ b
        Right slot  -> case sub of
          OneHanded -> let readyMsgs = (   T.concat [ "You wield the ", wpnSing, " with your ", pp slot, "." ]
                                       , ( T.concat [ serialize d
                                                    , " wields "
                                                    , aOrAn wpnSing
                                                    , " with "
                                                    , poss
                                                    , " "
                                                    , pp slot
                                                    , "." ]
                                         , otherPCIds ) )
                       in moveReadiedItem i a slot wpnId readyMsgs
          TwoHanded
            | all (isSlotAvail em) [ RHandS, LHandS ] ->
                let readyMsgs = ( "You wield the " <> wpnSing <> " with both hands."
                                , ( T.concat [ serialize d, " wields ", aOrAn wpnSing, " with both hands." ]
                                  , otherPCIds ) )
                in moveReadiedItem i a BothHandsS wpnId readyMsgs
            | otherwise -> let b = mkBroadcast i $ "Both hands are required to wield the " <> wpnSing <> "."
                           in a & _3 <>~ b
  where
    poss       = mkPossPro . getSex i $ ms
    otherPCIds = i `delete` pcIds d


getAvailWpnSlot :: MudState -> Id -> EqMap -> Either T.Text Slot
getAvailWpnSlot ms i em = let h@(otherHand -> oh) = getHand i ms in
    maybe (Left "You're already wielding two weapons.") Right . findAvailSlot em . map getSlotForHand $ [ h, oh ]
  where
    getSlotForHand h = case h of RHand -> RHandS
                                 LHand -> LHandS
                                 _     -> patternMatchFail "getAvailWpnSlot getSlotForHand" [ showText h ]


getDesigWpnSlot :: MudState -> Sing -> EqMap -> RightOrLeft -> Either T.Text Slot
getDesigWpnSlot ms wpnSing em rol
  | isRingRol rol = Left $ "You can't wield " <> aOrAn wpnSing <> " with your finger!"
  | otherwise     = maybe (Right desigSlot) (Left . sorry) . M.lookup desigSlot $ em
  where
    sorry i = let s = getSing i ms in T.concat [ "You're already wielding "
                                               , aOrAn s
                                               , " with your "
                                               , pp desigSlot
                                               , "." ]
    desigSlot = case rol of R -> RHandS
                            L -> LHandS
                            _ -> patternMatchFail "getDesigWpnSlot desigSlot" [ showText rol ]


-- Readying armor:


readyArm :: Id
         -> MudState
         -> PCDesig
         -> Maybe RightOrLeft
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
         -> Id
         -> Sing
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyArm i ms d mrol a@(et, _, _, _) armId armSing | em <- et ! i, sub <- getArmSub armId ms =
    case maybe (getAvailArmSlot ms sub em) sorryCan'tWearThere mrol of
      Left  (mkBroadcast i -> b) -> a & _3 <>~ b
      Right slot                 -> moveReadiedItem i a slot armId . mkReadyArmMsgs $ sub
  where
    sorryCan'tWearThere rol = Left . T.concat $ [ "You can't wear ", aOrAn armSing, " on your ", pp rol, "." ]
    mkReadyArmMsgs = \case
      Head   -> putOnMsgs                     i d armSing
      Hands  -> putOnMsgs                     i d armSing
      Feet   -> putOnMsgs                     i d armSing
      Shield -> mkReadyMsgs "ready" "readies" i d armSing
      _      -> donMsgs                       i d armSing


getAvailArmSlot :: MudState -> ArmSub -> EqMap -> Either T.Text Slot
getAvailArmSlot ms (armSubToSlot -> slot) em = maybe (Left sorryFullArmSlot) Right . maybeSingleSlot em $ slot
  where
    sorryFullArmSlot | i <- em M.! slot, s <- getSing i ms = "You're already wearing " <> aOrAn s <> "."


-----


remove :: Action
remove p@AdviseNoArgs = advise p ["remove"] advice
  where
    advice = T.concat [ "Please specify one or more items to remove followed by the container you want to remove \
                        \them from, as in "
                      , quoteColor
                      , dblQuote "remove doll sack"
                      , dfltColor
                      , "." ]
remove p@(AdviseOneArg a) = advise p ["remove"] advice
  where
    advice = T.concat [ "Please also specify the container you want to remove it from, as in "
                      , quoteColor
                      , dblQuote $ "remove " <> a <> " sack"
                      , dfltColor
                      , "." ]
remove (Lower' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "remove" i $ logMsgs)
  where
    helper ms = let (d, pcInvCoins, rmInvCoins, conName, argsWithoutCon) = mkPutRemoveBindings i ms as
                in case T.uncons conName of
                  Just (c, not . T.null -> isn'tNull) | c == rmChar, isn'tNull -> if not . null . fst $ rmInvCoins
                    then shuffleRem i ms d (T.tail conName) True argsWithoutCon rmInvCoins procGecrMisRm
                    else (ms, (mkBroadcast i "You don't see any containers here.", []))
                  _ -> shuffleRem i ms d conName False argsWithoutCon pcInvCoins procGecrMisPCInv
remove p = patternMatchFail "remove" [ showText p ]


shuffleRem :: Id
           -> MudState
           -> PCDesig
           -> ConName
           -> IsConInRm
           -> Args
           -> (InvWithCon, CoinsWithCon)
           -> ((GetEntsCoinsRes, Maybe Inv) -> Either T.Text Inv)
           -> (MudState, ([Broadcast], [T.Text]))
shuffleRem i ms d conName icir as invCoinsWithCon@(invWithCon, _) f =
    let (conGecrs, conMiss, conRcs) = uncurry (resolveEntCoinNames i ms [conName]) invCoinsWithCon
    in if null conMiss && (not . null $ conRcs)
      then sorry "You can't remove something from a coin."
      else case f . head . zip conGecrs $ conMiss of
        Left  msg     -> sorry msg
        Right [conId] -> let conSing = getSing conId ms in if getType conId ms /= ConType
          then sorry $ theOnLowerCap conSing <> " isn't a container."
          else let invCoinsInCon       = getInvCoins conId ms
                   (gecrs, miss, rcs)  = uncurry (resolveEntCoinNames i ms as) invCoinsInCon
                   eiss                = zipWith (curry $ procGecrMisCon conSing) gecrs miss
                   ecs                 = map (procReconciledCoinsCon conSing) rcs
                   mnom                = mkMaybeNthOfM ms icir conId conSing invWithCon
                   (it, bs,  logMsgs ) = foldl' (helperPutRemEitherInv   i ms d Rem mnom conId i conSing)
                                                (ms^.invTbl, [], [])
                                                eiss
                   (ct, bs', logMsgs') = foldl' (helperPutRemEitherCoins i    d Rem mnom conId i conSing)
                                                (ms^.coinsTbl, bs, logMsgs)
                                                ecs
               in if notEmpty invCoinsInCon
                 then (ms & invTbl .~ it & coinsTbl .~ ct, (bs', logMsgs'))
                 else sorry $ "The " <> conSing <> " is empty."
        Right {} -> sorry "You can only remove things from one container at a time."
  where
    sorry msg = (ms, (mkBroadcast i msg, []))


-----


say :: Action
say p@AdviseNoArgs = advise p ["say"] advice
  where
    advice = T.concat [ "Please specify what you'd like to say, as in "
                      , quoteColor
                      , dblQuote "say nice to meet you, too"
                      , dfltColor
                      , "." ]
say p@(WithArgs i mq cols args@(a:_)) = getState >>= \ms -> if
  | getPlaFlag IsIncognito . getPla i $ ms -> wrapSend mq cols $ "You can't use the " <> dblQuote "say" <> " command \
                                                                 \while incognito."
  | T.head a == adverbOpenChar -> case parseAdverb . T.unwords $ args of
    Left  msg -> adviseHelper msg
    Right (adverb, rest@(T.words -> rs@(head -> r)))
      | T.head r == sayToChar, T.length r > 1 -> if length rs > 1
        then sayTo (Just adverb) (T.tail rest) |$| modifyState >=> bcastAndLog
        else adviseHelper adviceEmptySayTo
      | otherwise -> simpleSayHelper ms (Just adverb) rest >>= bcastAndLog
  | T.head a == sayToChar, T.length a > 1 -> if length args > 1
    then sayTo Nothing (T.tail . T.unwords $ args) |$| modifyState >=> bcastAndLog
    else adviseHelper adviceEmptySayTo
  | otherwise -> simpleSayHelper ms Nothing (T.unwords args) >>= bcastAndLog
  where
    parseAdverb (T.tail -> msg) = case T.break (== adverbCloseChar) msg of
      (_,   "")            -> Left adviceCloseChar
      ("",  _ )            -> Left adviceEmptyAdverb
      (" ", _ )            -> Left adviceEmptyAdverb
      (_,   x ) | x == acc -> Left adviceEmptySay
      (adverb, right)      -> Right (adverb, T.drop 2 right)
    aoc               = T.singleton adverbOpenChar
    acc               = T.singleton adverbCloseChar
    adviceCloseChar   = "An adverbial phrase must be terminated with a " <> dblQuote acc <> example
    example           = T.concat [ ", as in "
                                 , quoteColor
                                 , dblQuote $ "say " <> quoteWith' (aoc, acc) "enthusiastically" <> " nice to meet \
                                              \you, too"
                                 , dfltColor
                                 , "." ]
    adviceEmptyAdverb = T.concat [ "Please provide an adverbial phrase between "
                                 , dblQuote aoc
                                 , " and "
                                 , dblQuote acc
                                 , example ]
    adviceEmptySay    = "Please also specify what you'd like to say" <> example
    adviceEmptySayTo  = T.concat [ "Please also specify what you'd like to say, as in "
                                 , quoteColor
                                 , dblQuote $ "say " <> T.singleton sayToChar <> "taro nice to meet you, too"
                                 , dfltColor
                                 , "." ]
    adviseHelper      = advise p ["say"]
    sayTo maybeAdverb (T.words -> (target:rest@(r:_))) ms =
        let d        = mkStdDesig i ms DoCap
            invCoins = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms
        in if notEmpty invCoins
          then case uncurry (resolveRmInvCoins i ms [target]) invCoins of
            (_,                    [ Left [msg] ]) -> sorry msg
            (_,                    Right  _:_    ) -> sorry "You're talking to coins now?"
            ([ Left  msg        ], _             ) -> sorry msg
            ([ Right (_:_:_)    ], _             ) -> sorry "Sorry, but you can only say something to one person at a \
                                                            \time."
            ([ Right [targetId] ], _             ) | targetSing <- getSing targetId ms -> case getType targetId ms of
                PCType  -> let targetDesig = serialize . mkStdDesig targetId ms $ Don'tCap
                           in either sorry (sayToHelper d targetId targetDesig) parseRearAdverb
                MobType -> either sorry (sayToMobHelper d targetSing) parseRearAdverb
                _       -> sorry $ "You can't talk to " <> aOrAn targetSing <> "."
            x -> patternMatchFail "say sayTo" [ showText x ]
          else sorry "You don't see anyone here to talk to."
      where
        sorry msg       = (ms, (mkBroadcast i . nlnl $ msg, []))
        parseRearAdverb = case maybeAdverb of
          Just adverb                          -> Right (adverb <> " ", "", formatMsg . T.unwords $ rest)
          Nothing | T.head r == adverbOpenChar -> case parseAdverb . T.unwords $ rest of
                      Right (adverb, rest') -> Right ("", " " <> adverb, formatMsg rest')
                      Left  msg             -> Left  msg
                  | otherwise -> Right ("", "", formatMsg . T.unwords $ rest)
        sayToHelper d targetId targetDesig (frontAdv, rearAdv, msg) =
            let toSelfMsg         = T.concat [ "You say ",            frontAdv, "to ", targetDesig, rearAdv, ", ", msg ]
                toSelfBroadcast   = head . mkBroadcast i . nlnl $ toSelfMsg
                toTargetMsg       = T.concat [ serialize d, " says ", frontAdv, "to you",           rearAdv, ", ", msg ]
                toTargetBroadcast = head . mkBroadcast targetId . nlnl $ toTargetMsg
                toOthersMsg       = T.concat [ serialize d, " says ", frontAdv, "to ", targetDesig, rearAdv, ", ", msg ]
                toOthersBroadcast = (nlnl toOthersMsg, pcIds d \\ [ i, targetId ])
            in (ms, ([ toSelfBroadcast, toTargetBroadcast, toOthersBroadcast ], [ parsePCDesig i ms toSelfMsg ]))
        sayToMobHelper d targetSing (frontAdv, rearAdv, msg) =
            let toSelfMsg         = T.concat [ "You say ", frontAdv, "to ", theOnLower targetSing, rearAdv, ", ", msg ]
                toOthersMsg       = T.concat [ serialize d
                                             , " says "
                                             , frontAdv
                                             , "to "
                                             , theOnLower targetSing
                                             , rearAdv
                                             , ", "
                                             , msg ]
                toOthersBroadcast = (nlnl toOthersMsg, i `delete` pcIds d)
                (pt, hint)        = firstMobSay i $ ms^.plaTbl
            in (ms & plaTbl .~ pt, ((toOthersBroadcast :) . mkBroadcast i $ toSelfMsg <> hint, [toSelfMsg]))
    sayTo maybeAdverb msg _ = patternMatchFail "say sayTo" [ showText maybeAdverb, msg ]
    formatMsg                 = dblQuote . capitalizeMsg . punctuateMsg
    bcastAndLog (bs, logMsgs) = bcast bs >> (unless (null logMsgs) . logPlaOut "say" i $ logMsgs)
    simpleSayHelper ms (maybe "" (" " <>) -> adverb) (formatMsg -> msg) =
        let d                 = mkStdDesig i ms DoCap
            toSelfMsg         = T.concat [ "You say", adverb, ", ", msg ]
            toSelfBroadcast   = mkBroadcast i . nlnl $ toSelfMsg
            toOthersMsg       = T.concat [ serialize d, " says", adverb, ", ", msg ]
            toOthersBroadcast = (nlnl toOthersMsg, i `delete` pcIds d)
        in return (toOthersBroadcast : toSelfBroadcast, [toSelfMsg])
say p = patternMatchFail "say" [ showText p ]


firstMobSay :: Id -> PlaTbl -> (PlaTbl, T.Text)
firstMobSay i pt = if pt^.ind i.to (getPlaFlag IsNotFirstMobSay)
  then (pt, "")
  else let msg = T.concat [ hintANSI
                          , "Hint:"
                          , noHintANSI
                          , " to communicate with non-player characters, use the "
                          , dblQuote "ask"
                          , " command. For example, to ask a city guard about crime, type "
                          , quoteColor
                          , dblQuote "ask guard crime"
                          , dfltColor
                          , "." ]
       in (pt & ind i %~ setPlaFlag IsNotFirstMobSay True, nlnlPrefix . nlnl $ msg)


-----


setAction :: Action
setAction (NoArgs i mq cols) = getState >>= \ms ->
    let names  = styleAbbrevs Don'tBracket settingNames
        values = map showText [ cols, getPageLines i ms ]
    in multiWrapSend mq cols [ pad 9 (n <> ": ") <> v | n <- names | v <- values ] >> logPlaExecArgs "set" [] i
setAction (LowerNub' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastNl bs >> (unless (null logMsgs) . logPlaOut "set" i $ logMsgs)
  where
    helper ms = let (p, msgs, logMsgs) = foldl' helperSettings (getPla i ms, [], []) as
                in (ms & plaTbl.ind i .~ p, (mkBroadcast i . T.unlines $ msgs, logMsgs))
setAction p = patternMatchFail "setAction" [ showText p ]


settingNames :: [T.Text]
settingNames = [ "columns", "lines" ]


helperSettings :: (Pla, [T.Text], [T.Text]) -> T.Text -> (Pla, [T.Text], [T.Text])
helperSettings a@(_, msgs, _) arg@(T.length . T.filter (== '=') -> noOfEqs)
  | or [ noOfEqs /= 1, T.head arg == '=', T.last arg == '=' ] =
      let msg    = dblQuote arg <> " is not a valid argument."
          advice = T.concat [ " Please specify the setting you want to change, followed immediately by "
                            , dblQuote "="
                            , ", followed immediately by the new value you want to assign, as in "
                            , quoteColor
                            , dblQuote "set columns=80"
                            , dfltColor
                            , "." ]
          f      = any (advice `T.isInfixOf`) msgs ? (++ [msg]) :? (++ [ msg <> advice ])
      in a & _2 %~ f
helperSettings a (T.breakOn "=" -> (name, T.tail -> value)) =
    maybe notFound found . findFullNameForAbbrev name $ settingNames
  where
    notFound    = appendMsg $ dblQuote name <> " is not a valid setting name."
    appendMsg m = a & _2 <>~ [m]
    found       = \case "columns" -> procEither (changeSetting minCols      maxCols      "columns" columns  )
                        "lines"   -> procEither (changeSetting minPageLines maxPageLines "lines"   pageLines)
                        t         -> patternMatchFail "helperSettings found" [t]
      where
        procEither f = either appendMsg f parseInt
        parseInt     = case (reads . T.unpack $ value :: [(Int, String)]) of [(x, "")] -> Right x
                                                                             _         -> sorryParse
        sorryParse   = Left . T.concat $ [ dblQuote value
                                         , " is not a valid value for the "
                                         , dblQuote name
                                         , " setting." ]
    changeSetting minVal@(showText -> minValTxt) maxVal@(showText -> maxValTxt) settingName lens x
      | not . inRange (minVal, maxVal) $ x = appendMsg . T.concat $ [ capitalize settingName
                                                                    , " must be between "
                                                                    , minValTxt
                                                                    , " and "
                                                                    , maxValTxt
                                                                    , "." ]
      | otherwise = let msg = T.concat [ "Set ", settingName, " to ", showText x, "." ] in
          appendMsg msg & _1.lens .~ x & _3 <>~ [msg]


-----


typo :: Action
typo p@AdviseNoArgs = advise p ["typo"] advice
  where
    advice = T.concat [ "Please describe the typo you've found, as in "
                      , quoteColor
                      , dblQuote "typo 'accross from the fireplace' should be 'across from the fireplace'"
                      , dfltColor
                      , "." ]
typo p = bugTypoLogger p TypoLog


-----


unready :: Action
unready p@AdviseNoArgs = advise p ["unready"] advice
  where
    advice = T.concat [ "Please specify one or more items to unready, as in "
                      , quoteColor
                      , dblQuote "unready sword"
                      , dfltColor
                      , "." ]
unready (LowerNub' i as) = helper |$| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> (unless (null logMsgs) . logPlaOut "unready" i $ logMsgs)
  where
    helper ms = let d                      = mkStdDesig i ms DoCap
                    is                     = M.elems . getEqMap i $ ms
                    (gecrs, miss, rcs)     = resolveEntCoinNames i ms as is mempty
                    eiss                   = zipWith (curry procGecrMisPCEq) gecrs miss
                    bs                     = rcs |!| mkBroadcast i "You can't unready coins."
                    (et, it, bs', logMsgs) = foldl' (helperUnready i ms d) (ms^.eqTbl, ms^.invTbl, bs, []) eiss
                in if not . null $ is
                  then (ms & eqTbl .~ et & invTbl .~ it, (bs', logMsgs))
                  else (ms, (mkBroadcast i dudeYou'reNaked, []))
unready p = patternMatchFail "unready" [ showText p ]


helperUnready :: Id
              -> MudState
              -> PCDesig
              -> (EqTbl, InvTbl, [Broadcast], [T.Text])
              -> Either T.Text Inv
              -> (EqTbl, InvTbl, [Broadcast], [T.Text])
helperUnready i ms d a = \case
  Left  (mkBroadcast i -> b) -> a & _3 <>~ b
  Right targetIds            -> let (bs, msgs) = mkUnreadyDescs i ms d targetIds
                                in a & _1.ind i %~ M.filter (`notElem` targetIds)
                                     & _2.ind i %~ (sortInv ms . (++ targetIds))
                                     & _3 <>~ bs
                                     & _4 <>~ msgs


mkUnreadyDescs :: Id
               -> MudState
               -> PCDesig
               -> Inv
               -> ([Broadcast], [T.Text])
mkUnreadyDescs i ms d targetIds = first concat . unzip $ [ helper icb | icb <- mkIdCountBothList i ms targetIds ]
  where
    helper (targetId, count, b@(targetSing, _)) = if count == 1
      then let toSelfMsg   = T.concat [ "You ",           mkVerb targetId SndPer, " the ",   targetSing, "." ]
               toOthersMsg = T.concat [ serialize d, " ", mkVerb targetId ThrPer, " ", aOrAn targetSing, "." ]
           in ((toOthersMsg, otherPCIds) : mkBroadcast i toSelfMsg, toSelfMsg)
      else let toSelfMsg   = T.concat [ "You "
                                      , mkVerb targetId SndPer
                                      , " "
                                      , showText count
                                      , " "
                                      , mkPlurFromBoth b
                                      , "." ]
               toOthersMsg = T.concat [ serialize d
                                      , " "
                                      , mkVerb targetId ThrPer
                                      , " "
                                      , showText count
                                      , " "
                                      , mkPlurFromBoth b
                                      , "." ]
           in ((toOthersMsg, otherPCIds) : mkBroadcast i toSelfMsg, toSelfMsg)
    mkVerb targetId person = case getType targetId ms of
      ClothType -> case getCloth targetId ms of
        Earring  -> mkVerbRemove  person
        NoseRing -> mkVerbRemove  person
        Necklace -> mkVerbTakeOff person
        Bracelet -> mkVerbTakeOff person
        Ring     -> mkVerbTakeOff person
        Backpack -> mkVerbTakeOff person
        _        -> mkVerbDoff    person
      ConType -> mkVerbTakeOff person
      WpnType | person == SndPer -> "stop wielding"
              | otherwise        -> "stops wielding"
      ArmType -> case getArmSub targetId ms of
        Head   -> mkVerbTakeOff person
        Hands  -> mkVerbTakeOff person
        Feet   -> mkVerbTakeOff person
        Shield -> mkVerbUnready person
        _      -> mkVerbDoff    person
      t -> patternMatchFail "mkUnreadyDescs mkVerb" [ showText t ]
    mkVerbRemove  = \case SndPer -> "remove"
                          ThrPer -> "removes"
    mkVerbTakeOff = \case SndPer -> "take off"
                          ThrPer -> "takes off"
    mkVerbDoff    = \case SndPer -> "doff"
                          ThrPer -> "doffs"
    mkVerbUnready = \case SndPer -> "unready"
                          ThrPer -> "unreadies"
    otherPCIds    = i `delete` pcIds d


mkIdCountBothList :: Id -> MudState -> Inv -> [(Id, Int, BothGramNos)]
mkIdCountBothList i ms targetIds =
    let boths@(mkCountList -> counts) = [ getEffBothGramNos i ms targetId | targetId <- targetIds ]
    in nubBy equalCountsAndBoths . zip3 targetIds counts $ boths
  where
    equalCountsAndBoths (_, c, b) (_, c', b') = c == c' && b == b'


-----


uptime :: Action
uptime (NoArgs i mq cols) = do
    wrapSend mq cols =<< uptimeHelper =<< getUptime
    logPlaExec "uptime" i
uptime p = withoutArgs uptime p


getUptime :: MudStack Int
getUptime = let start = asks $ view startTime
                now   = liftIO . getTime $ Monotonic
            in (-) <$> sec `fmap` now <*> sec `fmap` start


uptimeHelper :: Int -> MudStack T.Text
uptimeHelper up = helper <$> (fmap . fmap) getSum getRecordUptime
  where
    helper         = maybe mkUptimeTxt (\recUp -> up > recUp ? mkNewRecTxt :? mkRecTxt recUp)
    mkUptimeTxt    = mkTxtHelper "."
    mkNewRecTxt    = mkTxtHelper . T.concat $ [ " - "
                                              , newRecordColor
                                              , "it's a new record!"
                                              , dfltColor ]
    mkRecTxt recUp = mkTxtHelper $ " (record uptime: " <> renderIt recUp <> ")."
    mkTxtHelper    = ("Up " <>) . (renderIt up <>)
    renderIt       = T.pack . renderSecs . toInteger


getRecordUptime :: MudStack (Maybe (Sum Int))
getRecordUptime = mIf (liftIO . doesFileExist $ uptimeFile)
                      (liftIO readUptime `catch` (emptied . fileIOExHandler "getRecordUptime"))
                      (return Nothing)
  where
    readUptime = Just . Sum . read <$> readFile uptimeFile


-----


whoAdmin :: Action
whoAdmin (NoArgs i mq cols) = (multiWrapSend mq cols =<< helper =<< getState) >> logPlaExec "whoadmin" i
  where
    helper ms =
        let adminIds                              = [ ai | ai <-  getLoggedInAdminIds ms
                                                    , not . getPlaFlag IsIncognito . getPla ai $ ms ]
            (adminIds', self) | i `elem` adminIds = (i `delete` adminIds, selfColor <> getSing i ms <> dfltColor)
                              | otherwise         = (           adminIds, ""                                    )
            adminSings                            = [ s | adminId <- adminIds', let s = getSing adminId ms
                                                                              , then sortWith by s ]
            adminAbbrevs                          = dropBlanks . (self :) . styleAbbrevs Don'tBracket $ adminSings
            footer                                = [ noOfAdmins adminIds <> " logged in." ]
        in return (null adminAbbrevs ? footer :? T.intercalate ", " adminAbbrevs : footer)
      where
        noOfAdmins (length -> num) | num == 1  = "1 administrator"
                                   | otherwise = showText num <> " administrators"
whoAdmin p = withoutArgs whoAdmin p


-----


whoAmI :: Action
whoAmI (NoArgs i mq cols) = (wrapSend mq cols =<< helper =<< getState) >> logPlaExec "whoami" i
  where
    helper ms = let s         = getSing i ms
                    (sexy, r) = (uncapitalize . showText *** uncapitalize . showText) . getSexRace i $ ms
                in return . T.concat $ [ "You are ", knownNameColor, s, dfltColor, " (a ", sexy, " ", r, ")." ]
whoAmI p = withoutArgs whoAmI p
