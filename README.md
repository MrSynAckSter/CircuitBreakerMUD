#Circuit Breaker - a fork of CurryMUD for Lainchan
This intended as a base to work off of for a collaborative project on lainchan.org to code up a multi user dungeon with a distinctly cyberpunk style. 

Goals include: 

-a scripting system integrated into the command system of the mud to allow hacking based game play.  

-Cyberpunk themed dungeons and story arc 

-Baller Ascii art at every possible juncture of the interface. 

Longer term goals:

-Refactoring this thing to work of SSH, and adding all the paranoid security hardening that users of an imageboard with a /sec section demand. 



#Original Curry Mud Readme
A textual Multi-User Dungeon ("MUD") server in Haskell. (If you are unfamiliar with the term "MUD," please refer to [this Wikipedia article](http://en.wikipedia.org/wiki/MUD).)

CurryMUD is essentially the hobby project and brainchild of a single developer (me). It's been in active development for over 2 years, but is still very much a work in progress.

## My goals

My aim is to create a single unique, playable MUD named "CurryMUD." I am writing this MUD entirely in Haskell, from scratch.

Creating a framework which others can leverage to develop their own MUDs is _not_ an explicit goal of mine, nor is this a collaborative effort (I am not accepting PRs). Having said that, the code is available here on GitHub, so other parties _are_ free to examine the code and develop their own forks (in accordance with [the 3-clause BSD license](https://github.com/jasonstolaruk/CurryMUD/blob/master/LICENSE)).

CurryMUD will have the following features:

* Players will be offered an immersive virtual world environment.
* Content will be created, and development will proceed, with the aim of supporting a small community of players.
* Role-playing will be strictly enforced.
* Classless/skill-based.
* Permadeath. (When player characters die, they really die.)
* Some degree of player-created content will be allowed and encouraged.
* The state of the virtual world will be highly persisted upon server shutdown.
* As is common with most textual MUDs, client connections will be supported with a loose implementation of the telnet protocol.
* CurryMUD will always be free to play.

## What I have so far

* About 85 player commands and 45 administrator commands.
* Over 200 built-in emotes.
* Help files for all existing non-debug commands. Help topics.
* Commands have a consistent structure and a unique syntax for indicating target locations and quantities.
* Unique commands, accessible only when a player is in a particular room, may be created.
* The names of commands, as well as the names of the targets they act upon, may be abbreviated.
* Logging.
* ANSI color.
* Character creation.
* The virtual world is automatically persisted at regular intervals and at shutdown.
* Systems for reporting bugs and typos.
* Commands to aid in the process of resetting a forgotten password.
* NPCs can execute commands, either from within code or via the ":as" administrator command.
* PCs can introduce themselves to each other.
* PCs can "link" with each other so as to enable "tells."
* Question channel for OOC newbie Q&A.
* Players can create their own ad-hoc channels.
* Free-form emotes and built-in emotes may be used in "tells" and channel communications.
* Functionality enabling one-on-one communication between players and administrators.
* Weight and encumbrance.
* Volume and container capacity.
* Vessels for containing liquids. Vessels may be filled and emptied.
* Players can interact with permanent room fixtures that are not listed in a room's inventory.
* Objects can be configured to automatically disappear when left on the ground for some time.
* Smell and taste. Listen.
* Eating foods and drinking liquids. Digestion.
* Durational effects that can be paused and resumed.

I am still in the initial stage of developing basic commands. There is very little content in the virtual world.

## About the code

The code is available here on GitHub under the 3-clause BSD license (refer to the [LICENSE file](https://github.com/jasonstolaruk/CurryMUD/blob/master/LICENSE)). Please note that **I am not accepting PRs**.

* About 40,000 lines of code/text.
* About 95 modules, excluding tests.
* About 60 unit and property tests exist (I'm using the [tasty testing framework](https://hackage.haskell.org/package/tasty)).
* A `ReaderT` monad transformer stack with the world state inside a single `IORef`.
* `STM`-based concurrency.
* Using `aeson` (with `conduit`) and `sqlite-simple` for persistence.
* Heavy use of the `lens` library.
* Heavy use of GHC extensions, including:
  * `DuplicateRecordFields` (new in GHC 8)
  * `LambdaCase`
  * `MonadComprehensions`
  * `MultiWayIf`
  * `NamedFieldPuns`
  * `ParallelListComp`
  * `PatternSynonyms`
  * `RebindableSyntax`
  * `RecordWildCards`
  * `TupleSections`
  * `ViewPatterns`

### How to try it out

Linux and Mac OS X are supported. Sorry, but Windows is _not_ supported.

Please build with [stack](http://docs.haskellstack.org/en/stable/README.html) (otherwise, I cannot guarantee that CurryMUD will build on your machine).

0. [Install stack.](http://docs.haskellstack.org/en/stable/install_and_upgrade/)
0. Clone the repo from your home directory (the server expects to find various folders under `$HOME/CurryMUD`).
0. Inside `$HOME/CurryMUD`, run `stack setup` to get GHC 8 on your machine. (The `stack.yaml` file points to the [nightly resolver](https://www.stackage.org/snapshots), which uses GHC 8.)
0. Run `stack build` to compile the `curry` binary and libraries.
0. Run `stack install` to copy the `curry` binary to `$HOME/.local/bin`.
0. Execute the `curry` binary.
0. Telnet to `localhost` port 9696 to play.

CurryMUD presently cannot be loaded into GHCi due to [a GHC bug](https://ghc.haskell.org/trac/ghc/ticket/12007).

## How to contact me

Feel free to email me at the address associated with [my GitHub account](https://github.com/jasonstolaruk) if you have any questions.
