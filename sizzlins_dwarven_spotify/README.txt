=========================================================
      HOW TO ADD CUSTOM MUSIC TO DWARFTIFY
=========================================================

Dwarftify natively supports loading your own custom music directly into the player! 

However, because of how the Dwarf Fortress audio engine is hardcoded, custom audio tracks cannot be hot-loaded into an existing save file. You MUST generate a new world to allow the vanilla engine to parse your new audio files and assign them internal IDs.

Follow these steps exactly to add your own music:

STEP 1: PREPARE YOUR MUSIC
---------------------------------------------------------
Find the custom tracks you want to add. 
IMPORTANT: They MUST be valid ".ogg" format audio files. You cannot just rename a ".mp3" to ".ogg"—you must actually convert the file using an audio converter!

STEP 2: LOCATE THE CUSTOM MUSIC FOLDER
---------------------------------------------------------
Navigate to where your computer stores installed_mod (might be different for other machines, mine was C:\Users\LOQ\AppData\Roaming\Bay 12 Games\Dwarf Fortress\data\installed_mods\sizzlins_dwarven_spotify), you will find a folder named "dfhack-config" inside the mod folder. Copy this "dfhack-config" folder and paste it directly into your root Dwarf Fortress installation folder:
\Steam\steamapps\common\Dwarf Fortress\

This will safely merge it with your game's existing config folder.

STEP 3: ADD YOUR .OGG FILES
---------------------------------------------------------
Navigate to your newly pasted folder:
\Steam\steamapps\common\Dwarf Fortress\dfhack-config\dwarftify\custom_music\

You will see two example .ogg files inside. Delete these examples (or not, doesn't matter) and paste your own .ogg files into this folder!

STEP 4: RUN THE IN-GAME SYNC TOOL
---------------------------------------------------------
Launch Dwarf Fortress and load into ANY existing world or save file.
Open the DFHack terminal and type "gui/dwarftify" to open the music player.

While the music player is open, press Shift+S on your keyboard.
This runs the Dwarftify Sync tool. It will scan your custom_music folder, safely reformat the files to prevent game-crashing buffer overflows, and automatically generate a local Dwarf Fortress Mod for you called "Dwarftify Custom Music"!

STEP 5: RESTART THE GAME
---------------------------------------------------------
Close Dwarf Fortress entirely and reopen it. This forces the game to scan for the newly generated mod.

STEP 6: CREATE A NEW WORLD
---------------------------------------------------------
Click "Create New World".
Before generating, open the Mod Manager for the new world.
Ensure that the mod named "Dwarftify Custom Music" is ENABLED in your active mod list!
(If multiple versions are present, prioritize enabling the one with the highest version number)

Generate the world and embark!

STEP 7: ENJOY
---------------------------------------------------------
Once you are in your new fortress, open gui/dwarftify. 
Your custom tracks will now appear in the Browse tab under the artist "Custom Music", ready to be played.

=========================================================
TROUBLESHOOTING
=========================================================
- "My track says it was skipped/rejected during Sync!"
Make sure the file is a true .ogg file. Dwarftify validates the "OggS" file header to prevent you from accidentally crashing Dwarf Fortress with invalid audio formats.

- "My track is playing, but there is no sound!"
Make sure your .ogg file is not corrupted and plays correctly in a standard media player before syncing.

- "Do I have to do this every time I play?"
No! Once you generate the world with the custom music mod enabled, the music is permanently embedded in that save file. You only have to repeat this process if you want to add MORE new songs, which will require generating another new world.