## Account Repaired - simple addon to track repair costs sorted by armor type. 

*Use as a module with **AccountPlayed** or use the command `/arepaired show`* 

Features:

* View your account's total gold spent on repairs, grouped by armor type (Cloth / Leather / Mail / Plate)
* Sorted by (armor type / total account repairs) as a percentage
* Small popup UI (resize, drag, move, and scroll as you please!)
* Minimap button to toggle UI (fades when mouse is not over minimap)
* Hover over armor types to get a popup of all characters making up the repair cost
* Right-click an armor type bar to open a character management panel (delete characters, view breakdown)
* Filter by Today / Week / Month / All Time
* Press Escape to close window
* Character strip showing your current character's repair costs across all time periods
* If [Account Played](https://www.curseforge.com/wow/addons/account-played) is installed, a button will appear to quickly switch to the played time window

Usage:
```
* `/arepaired`         - list available commands
* `/arepaired show`    - toggle repair cost window
* `/arepaired minimap` - toggle the AccountRepaired minimap icon on/off
* `/arepaired reset`   - reset the position of the minimap button to the bottom left of the minimap

Debug Commands:
* `/ardebug` - prints a list of all stored characters to chat in the following format: `Realm-Name: TotalRepaired (CLASS/ARMORTYPE)`
* `/ardelete CharName-RealmName` - delete a character's stored repair data
```
Account Played Integration:

* Made by the same author as [Account Played](https://www.curseforge.com/wow/addons/account-played) — both addons are designed to complement each other
* If Account Played is installed, a button appears at the bottom of the AccountRepaired window to instantly switch to the played time UI
* If Account Played is **not** installed, AccountRepaired works fully standalone with no dependencies

Contributing:

* PRs/Issues welcome!
* For faster response/general feedback, feel free to reach out via email: jeremy51b5@pm.me
