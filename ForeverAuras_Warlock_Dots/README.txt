Forever Auras: Warlock
Version 0.1.0
Author: Ally

INSTALL
=======
The folder name and TOC basename MUST match exactly:

    Interface\AddOns\ForeverAuras_Warlock\
        ForeverAuras_Warlock.toc
        ForeverAuras_Warlock.lua
        README.txt

Then fully restart WoW if this is a brand-new addon folder.

ROW / ORDER
===========
Curse | Bane | Corruption | Siphon Life | Immolate

DISPLAY RULES
=============
The entire tracker is hidden with no target, a friendly target, or a dead target.

Ordinary DoTs:
    > 3 sec left    = hidden
    <= 3 sec left   = icon + decimal countdown, no glow
    missing         = icon + animated glow

BANE SLOT
=========
Bane of Agony, Bane of Doom, and Bane of Havoc share ONE slot.

If one of those is on / was last applied to the target, that Bane owns the slot
and supplies the icon/timer. The others do not matter.

Fresh targets default to a missing/glowing Bane of Agony icon.

CURSE SLOT
==========
Hidden on ordinary targets until you demonstrate that the target matters by
casting a raid Curse on it.

Curse of Recklessness:
    duration: 2:00
    tracker remains armed for: 2:30 from cast
    icon appears at <= 5 sec
    after expiration it glows for the remaining 30 sec grace period

Curse of the Elements:
    duration: 5:00
    tracker remains armed for: 5:30 from cast
    icon appears at <= 5 sec
    after expiration it glows for the remaining 30 sec grace period

IMMOLATE SLOT
=============
Hidden until Immolate has been cast on that specific target.
The slot is remembered for 30 seconds from the cast.

COMMANDS
========
/fa test
    Shows a 10-second test row.

/fa unlock
    Makes the row draggable.

/fa lock
    Saves position and returns to normal behavior.

/fa reset
    Reset position.

/fa clear
    Clear remembered target state (useful while testing).

/fa on
/fa off
/fa status

EASY EDITS
==========
Near the top of ForeverAuras_Warlock.lua:

    ICON_SIZE = 30
    ICON_SPACING = 4
    NORMAL_WARNING = 3.0
    CURSE_WARNING = 5.0
    IMMOLATE_MEMORY = 30.0

Those are deliberately kept together so minor visual/timing changes are easy.

BASE-BUILD LIMITATION
=====================
This first version tracks your own successful spell casts by target GUID and
resyncs actual target auras whenever Forever allows readable out-of-combat aura
data.

That means another Warlock's Corruption / Bane / Siphon Life does not satisfy
your tracker.

Forever can protect combat aura identity/timers. Therefore a dispel, resist,
automatic talent-based refresh, or other aura change that occurs during combat
without a matching successful cast from you may require a later secure
AuraContainer backend. The UI/order/rules are intentionally separated from the
tracking layer so that backend can be swapped in without rebuilding the addon.
