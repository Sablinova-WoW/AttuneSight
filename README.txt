AttuneSight v1.0.0 — Synastria / WoW 3.3.5a

PURPOSE
Show a customizable marker on originally Bind-on-Equip equipment for
which no variant has been attuned across the account. Originally BoE
items remain eligible after becoming soulbound. Originally BoP items
are excluded. This addon neither moves nor modifies items.

COMPATIBILITY
Blizzard inventory, live personal and guild banks; Bagnon; OmniInventory;
optional third-party button adapters. Offline bank snapshots are excluded.
All inventory addon integrations need in-game validation on Synastria.

APPEARANCE
Esc > Interface > AddOns > AttuneSight (or /as)
- Enable markers and optional inner outline
- Badge, corner ribbon or white dot
- Separate marker and outline color pickers with opacity
- Marker size 10-50 (16 default), five positions including Center
  (Center is unavailable for the corner ribbon)
- Preview changes immediately; settings persist in AttuneSightDB

TOOLS
Esc > Interface > AddOns > AttuneSight > Tools
Refresh cached attunement data or check a current bag item ID / UI.

PERFORMANCE
The addon uses inventory events and item-button hooks rather than a
constant full-inventory polling loop. Item-template BoE information
and resolved equipment information are cached; account attunement
results expire or clear when Synastria reports an attunement event.
Appearance changes coalesce into the next update frame.

COMMANDS
/as, /attunesight, /asight    Open appearance settings
/attunesight on|off          Toggle markers
/attunesight edge            Toggle inner outline
/attunesight style 1|2|3     Choose marker style
/attunesight refresh         Clear attunement cache and rescan
/attunesight check ITEMID    Explain bag item eligibility
/attunesight ui ITEMID       Inspect rendered bag markers

INSTALL
Copy the AttuneSight folder into Interface/AddOns. A full WoW restart
may be required when adding the textures for the FIRST time; routine
Lua-only updates can use /reload. Keep one version installed.

RELEASE VALIDATION
Before public distribution, confirm /as navigation with Interface Options
both open and closed; verify markers in Blizzard bags, Bagnon and live banks.
Third-party inventory support requires testing with those addons installed.

SUPPORT
The Tools page and check/ui commands are retained for diagnosing
Synastria-specific item eligibility and button-rendering problems.
