-- Dungeons for Mac - app window
-- Compiled into an applet with osacompile the first time the app opens.
-- Kept to plain ASCII on purpose. All the real work happens in core.sh.


on run
	try
		my mainLoop()
	on error errMsg number errNum
		if errNum is not -128 then
			try
				display dialog "Something went wrong:" & return & return & errMsg buttons {"Quit"} default button "Quit" with title "Dungeons for Mac"
			end try
		end if
	end try
end run

-- ---------------------------------------------------------------------------
-- Plumbing
-- ---------------------------------------------------------------------------
on corePath()
	return (POSIX path of (path to home folder)) & "Library/Application Support/DungeonsForMac/app/core.sh"
end corePath

on core(argText)
	return do shell script "/bin/bash " & quoted form of (my corePath()) & " " & argText
end core

on dlg(msg, btns, defBtn)
	try
		set r to display dialog msg buttons btns default button defBtn with title "Dungeons for Mac" with icon (path to resource "applet.icns")
	on error errMsg number errNum
		if errNum is -128 then error number -128
		set r to display dialog msg buttons btns default button defBtn with title "Dungeons for Mac"
	end try
	return button returned of r
end dlg

on valueFor(rawText, k)
	set keyPrefix to k & "="
	repeat with ln in (paragraphs of rawText)
		set t to ln as text
		if t starts with keyPrefix then
			if (length of t) > (length of keyPrefix) then
				return text ((length of keyPrefix) + 1) thru -1 of t
			else
				return ""
			end if
		end if
	end repeat
	return ""
end valueFor

on splitBar(s)
	set oldTID to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "|"
	set parts to text items of s
	set AppleScript's text item delimiters to oldTID
	return parts
end splitBar

on restFrom(parts, n)
	if (count of parts) < n then return ""
	set oldTID to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "|"
	set joined to (items n thru -1 of parts) as text
	set AppleScript's text item delimiters to oldTID
	return joined
end restFrom

on afterBar(s)
	set o to offset of "|" in s
	if o is 0 then return s
	if o is (length of s) then return ""
	return text (o + 1) thru -1 of s
end afterBar

on onOff(v)
	if v is "1" then return "On"
	return "Off"
end onOff

on rendererLabel(v)
	if v is "dxvk" then return "DXVK (Vulkan over MoltenVK)"
	if v is "wined3d" then return "WineD3D (OpenGL, safe mode)"
	return "DXMT (Metal)"
end rendererLabel

on fpsLabel(v)
	if v is "0" then return "No cap"
	return v & " FPS"
end fpsLabel

on launchLabel(v)
	if v is "bootstrap" then return "Through Dungeons.exe"
	return "Direct"
end launchLabel

on argsLabel(v)
	if v is "" then return "None"
	return v
end argsLabel

-- ---------------------------------------------------------------------------
-- Background tasks with a progress bar
-- ---------------------------------------------------------------------------
on runJob(jobArgs, headline)
	if jobArgs is not "" then
		my core("start " & jobArgs)
	end if
	set progress total steps to -1
	set progress completed steps to 0
	set progress description to headline
	set progress additional description to "Starting..."
	set outcome to "error"
	set msg to ""
	try
		repeat
			delay 0.5
			set p to my core("poll")
			set parts to my splitBar(p)
			if (count of parts) >= 3 then
				if (item 1 of parts) is "done" then
					set outcome to item 2 of parts
					set msg to my restFrom(parts, 3)
					exit repeat
				else
					set msg to my restFrom(parts, 3)
					set pct to -1
					try
						set pct to (item 2 of parts) as integer
					end try
					if pct < 0 then
						set progress total steps to -1
					else
						set progress total steps to 100
						set progress completed steps to pct
					end if
					set progress additional description to msg
				end if
			end if
		end repeat
	on error errMsg number errNum
		if errNum is -128 then
			try
				my core("cancel")
			end try
			set outcome to "cancelled"
			set msg to "Stopped. Downloads that already finished are kept, so the next try is faster."
		else
			set outcome to "error"
			set msg to errMsg
		end if
	end try
	set progress total steps to 0
	set progress completed steps to 0
	set progress description to ""
	set progress additional description to ""
	return {outcome, msg}
end runJob

on reportResult(res, successText)
	set outcome to item 1 of res
	set msg to item 2 of res
	if outcome is "ok" then
		if msg is "" then set msg to successText
		my dlg(msg, {"OK"}, "OK")
		return true
	else if outcome is "cancelled" then
		my dlg(msg, {"OK"}, "OK")
	else
		set b to my dlg("That didn't work:" & return & return & msg, {"Show Log", "OK"}, "OK")
		if b is "Show Log" then my core("open-log")
	end if
	return false
end reportResult

-- ---------------------------------------------------------------------------
-- Main flow
-- ---------------------------------------------------------------------------
on mainLoop()
	repeat
		set statusRaw to my core("status")
		if (my valueFor(statusRaw, "busy")) is "1" then
			set res to my runJob("", "Dungeons for Mac is working")
			my reportResult(res, "Done.")
		else if (my valueFor(statusRaw, "engine")) is not "1" then
			set b to my dlg(my welcomeText(), {"Quit", "Set Up"}, "Set Up")
			if b is "Quit" then return
			if my preflightOK() then
				set res to my runJob("setup", "Setting up Dungeons for Mac")
				my reportResult(res, "Setup finished.")
			end if
		else if (my valueFor(statusRaw, "game")) is not "1" then
			if (my valueFor(statusRaw, "signed_in")) is not "1" then
				set b to my dlg(my signInText(), {"Quit", "More...", "Sign In"}, "Sign In")
				if b is "Quit" then return
				if b is "More..." then
					if (my moreMenu()) is "quit" then return
				else
					set res to my runJob("signin", "Signing in to Microsoft")
					my reportResult(res, "Signed in.")
				end if
			else
				set b to my dlg(my downloadText(), {"Quit", "More...", "Download"}, "Download")
				if b is "Quit" then return
				if b is "More..." then
					if (my moreMenu()) is "quit" then return
				else
					set res to my runJob("storeinstall", "Downloading Minecraft Dungeons")
					my reportResult(res, "Downloaded.")
				end if
			end if
		else
			set b to my dlg(my readyText(statusRaw), {"More...", "Settings...", "Play"}, "Play")
			if b is "Play" then
				if my startGame() then return
			else if b is "Settings..." then
				my settingsMenu()
			else
				if (my moreMenu()) is "quit" then return
			end if
		end if
	end repeat
end mainLoop

on welcomeText()
	return "Welcome! This sets up everything your Microsoft Store copy of Minecraft Dungeons needs on this Mac:" & return & return & "- Wine 11 (built from CrossOver 26.3's code) with the Xbox game runtime" & return & "- DXMT, which turns the game's Direct3D 11 into Apple Metal" & return & "- the Microsoft sign-in and download client" & return & "- Microsoft's Visual C++ runtimes" & return & return & "It downloads about 800 MB and takes 5 to 15 minutes. Everything lives in one folder that Uninstall removes completely."
end welcomeText

on signInText()
	return "Setup is done. Now sign in with the Microsoft account that bought Minecraft Dungeons in the Microsoft Store." & return & return & "A Microsoft sign-in window opens. Your password goes straight to Microsoft; the sign-in is kept in this Mac's Keychain." & return & return & "Note: this uses an unofficial Xbox client (Xodus). It only works for games your account owns."
end signInText

on downloadText()
	return "Signed in." & return & return & "Next, Dungeons for Mac asks Microsoft for your copy of Minecraft Dungeons and downloads it (about 6 GB). If your account doesn't own it, Microsoft refuses and nothing is downloaded." & return & return & "You can stop and resume the download any time."
end downloadText

on addGameText()
	return "Setup is done. Now add the game." & return & return & "You need the Launcher version of Minecraft Dungeons copied from a Windows PC: the folder that contains Dungeons.exe. A USB drive or a network share both work." & return & return & "Not sure how? Choose More... then How to copy the game from your PC."
end addGameText

on readyText(statusRaw)
	set t to "Ready to play Minecraft Dungeons." & return & return
	set t to t & "Graphics: " & my rendererLabel(my valueFor(statusRaw, "renderer")) & return
	set t to t & "Frame cap: " & my fpsLabel(my valueFor(statusRaw, "fps")) & return
	set t to t & "Sharp mode: " & my onOff(my valueFor(statusRaw, "sharp"))
	if (my valueFor(statusRaw, "running")) is "1" then
		set t to t & return & return & "The game is running right now."
	else
		set lastCode to my valueFor(statusRaw, "last_code")
		set lastSecs to my valueFor(statusRaw, "last_secs")
		if lastCode is not "" and lastCode is not "0" and (my valueFor(statusRaw, "launch")) is "direct" then
			set wasQuick to false
			try
				if (lastSecs as integer) < 90 then set wasQuick to true
			end try
			if wasQuick then
				set t to t & return & return & "Note: the last launch closed after " & lastSecs & " seconds (code " & lastCode & "). If the game didn't show up, try Settings > Graphics > DXVK, or More > Show log."
			end if
		end if
	end if
	return t
end readyText

on preflightOK()
	set pf to my core("preflight")
	if pf starts with "ok" then return true
	if pf starts with "rosetta" then
		set b to my dlg("This Mac needs Rosetta 2, Apple's translator for Intel apps. Wine runs through it." & return & return & "Install it now? macOS will ask for your password.", {"Not Now", "Install Rosetta"}, "Install Rosetta")
		if b is "Install Rosetta" then
			try
				do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges
			on error errMsg number errNum
				if errNum is not -128 then my dlg("Rosetta couldn't be installed:" & return & return & errMsg, {"OK"}, "OK")
				return false
			end try
			return my preflightOK()
		end if
		return false
	end if
	my dlg(my afterBar(pf), {"OK"}, "OK")
	return false
end preflightOK

on startGame()
	set r to my core("play")
	if r starts with "ok" then
		display notification "Starting Minecraft Dungeons. The very first launch can take a minute or two while macOS translates the game." with title "Dungeons for Mac"
		return true
	else if r starts with "running" then
		my dlg("Minecraft Dungeons is already running.", {"OK"}, "OK")
	else
		my dlg(my afterBar(r), {"OK"}, "OK")
	end if
	return false
end startGame

-- ---------------------------------------------------------------------------
-- Adding the game
-- ---------------------------------------------------------------------------
on addGame()
	try
		set f to choose folder with prompt "Choose the Minecraft Dungeons folder copied from your PC (the one with Dungeons.exe, or any folder above it):"
	on error
		return
	end try
	set p to POSIX path of f
	set d to my core("detect " & quoted form of p)
	set parts to my splitBar(d)
	set foundKind to item 1 of parts
	set sizeMB to "0"
	set sameVol to "0"
	if (count of parts) >= 4 then
		set sizeMB to item 2 of parts
		set sameVol to item 4 of parts
	end if
	if foundKind is "launcher" then
		set msg to "Found Minecraft Dungeons (Launcher version), about " & sizeMB & " MB."
		if sameVol is "1" then
			set b to my dlg(msg & return & return & "It's already on this Mac's drive. Move it in (instant, no extra space) or make a copy?", {"Back", "Copy", "Move"}, "Move")
		else
			set b to my dlg(msg & return & return & "Copy it into Dungeons for Mac now?", {"Back", "Copy"}, "Copy")
		end if
		if b is "Back" then return
		if b is "Move" then
			set howTo to "move"
		else
			set howTo to "copy"
		end if
		set res to my runJob("import " & quoted form of p & " " & howTo, "Adding Minecraft Dungeons")
		my reportResult(res, "Minecraft Dungeons is ready. Press Play!")
	else if foundKind is "store" then
		set b to my dlg(my storeText(), {"Back", "Try Anyway"}, "Back")
		if b is "Try Anyway" then
			set res to my runJob("import " & quoted form of p & " copy force", "Adding Minecraft Dungeons")
			my reportResult(res, "Copied.")
		end if
	else
		my dlg("No Minecraft Dungeons game files were found in that folder." & return & return & "Pick the folder that contains Dungeons.exe, or any folder above it.", {"OK"}, "OK")
	end if
end addGame

on storeText()
	return "This looks like the Microsoft Store version of Minecraft Dungeons." & return & return & "Store copies only pass their ownership check inside Windows, so they stop with 'can't verify ownership' anywhere else, Wine included." & return & return & "The Launcher version (from the Minecraft Launcher, with a normal install folder) is the one that runs here."
end storeText

on howToText()
	return "Copying the game from your Windows PC:" & return & return & "1. On the PC, open the Minecraft Launcher, then Minecraft Dungeons, then the Installation tab. It has to show a full folder path. A bare drive letter like C: means the Store version, which can't run on a Mac." & return & return & "2. Open that folder and copy its 'dungeons' folder (about 6-10 GB) to a USB drive, or share it on the network: right-click it, Properties, Sharing." & return & return & "3. For a share, on the Mac use Finder > Go > Connect to Server and type smb://YOUR-PC-NAME (a Tailscale IP works too)." & return & return & "4. Back here, choose Add Game Folder and pick it. The right files inside are found automatically."
end howToText

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
on settingsMenu()
	repeat
		set statusRaw to my core("status")
		set opts to {"Graphics: " & my rendererLabel(my valueFor(statusRaw, "renderer")), "Frame rate cap: " & my fpsLabel(my valueFor(statusRaw, "fps")), "Sharp mode (MetalFX upscaling): " & my onOff(my valueFor(statusRaw, "sharp")), "FPS counter (Metal HUD): " & my onOff(my valueFor(statusRaw, "hud")), "Start method: " & my launchLabel(my valueFor(statusRaw, "launch")), "Sync mode: " & my valueFor(statusRaw, "sync"), "Extra launch options: " & my argsLabel(my valueFor(statusRaw, "args")), "Reset all settings"}
		set pick to choose from list opts with title "Dungeons for Mac" with prompt "Choose a setting to change:" OK button name "Change" cancel button name "Done"
		if pick is false then return
		set pick to item 1 of pick
		if pick starts with "Graphics" then
			set g to choose from list {"DXMT - Metal, fastest (recommended)", "DXVK - Vulkan over MoltenVK (compatibility)", "WineD3D - OpenGL (safe mode, slowest)"} with title "Dungeons for Mac" with prompt "Graphics backend:" OK button name "Use This" cancel button name "Back"
			if g is not false then
				set g to item 1 of g
				if g starts with "DXMT" then
					my core("set renderer dxmt")
				else if g starts with "DXVK" then
					my core("set renderer dxvk")
				else
					my core("set renderer wined3d")
				end if
			end if
		else if pick starts with "Frame rate" then
			set g to choose from list {"30 FPS - coolest and quietest, best on battery", "60 FPS - smooth (recommended)", "No cap"} with title "Dungeons for Mac" with prompt "Frame rate cap:" OK button name "Use This" cancel button name "Back"
			if g is not false then
				set g to item 1 of g
				if g starts with "30" then
					my core("set fps 30")
				else if g starts with "60" then
					my core("set fps 60")
				else
					my core("set fps 0")
				end if
			end if
		else if pick starts with "Sharp" then
			if (my valueFor(statusRaw, "sharp")) is "1" then
				my core("set sharp 0")
			else
				set b to my dlg("Sharp mode keeps the game rendering at the normal size and uses Apple's MetalFX to upscale it to full Retina resolution. Sharper text and edges for a small GPU cost." & return & return & "Works with the DXMT graphics backend.", {"Back", "Turn On"}, "Turn On")
				if b is "Turn On" then my core("set sharp 1")
			end if
		else if pick starts with "FPS counter" then
			if (my valueFor(statusRaw, "hud")) is "1" then
				my core("set hud 0")
			else
				my core("set hud 1")
			end if
		else if pick starts with "Start method" then
			set g to choose from list {"Direct - start the game itself (faster)", "Through Dungeons.exe - like on Windows"} with title "Dungeons for Mac" with prompt "Start method:" OK button name "Use This" cancel button name "Back"
			if g is not false then
				if (item 1 of g) starts with "Direct" then
					my core("set launch direct")
				else
					my core("set launch bootstrap")
				end if
			end if
		else if pick starts with "Sync" then
			set g to choose from list {"msync - fastest (recommended)", "esync", "off - most compatible"} with title "Dungeons for Mac" with prompt "Sync mode:" OK button name "Use This" cancel button name "Back"
			if g is not false then
				set g to item 1 of g
				if g starts with "msync" then
					my core("set sync msync")
				else if g starts with "esync" then
					my core("set sync esync")
				else
					my core("set sync off")
				end if
			end if
		else if pick starts with "Extra" then
			set cur to my valueFor(statusRaw, "args")
			set d to display dialog "Extra command-line options for the game (advanced). Leave empty for none." default answer cur buttons {"Back", "Save"} default button "Save" with title "Dungeons for Mac"
			if button returned of d is "Save" then my core("set args " & quoted form of (text returned of d))
		else if pick starts with "Reset" then
			my core("reset-settings")
		end if
	end repeat
end settingsMenu

-- ---------------------------------------------------------------------------
-- More
-- ---------------------------------------------------------------------------
on moreMenu()
	set opts to {"Sign in again...", "Re-download / update the game...", "Add a Launcher-version game folder instead...", "How to copy the game from your PC", "Open the saves folder", "Back up saves to Documents", "Force-quit the game", "Repair the Windows layer...", "Minecraft Launcher (experimental)...", "Show log", "Create a diagnostic report", "About Dungeons for Mac", "Uninstall...", "Quit"}
	set pick to choose from list opts with title "Dungeons for Mac" with prompt "More options:" OK button name "Select" cancel button name "Back"
	if pick is false then return "back"
	set pick to item 1 of pick
	if pick starts with "Sign in again" then
		set res to my runJob("signin", "Signing in to Microsoft")
		my reportResult(res, "Signed in.")
	else if pick starts with "Re-download" then
		set res to my runJob("storeinstall", "Downloading Minecraft Dungeons")
		my reportResult(res, "Downloaded.")
	else if pick starts with "Add a Launcher" then
		my addGame()
	else if pick starts with "How to copy" then
		my dlg(my howToText(), {"OK"}, "OK")
	else if pick starts with "Open the saves" then
		set r to my core("open-saves")
		if r starts with "error" then my dlg(my afterBar(r), {"OK"}, "OK")
	else if pick starts with "Back up" then
		set r to my core("backup-saves")
		if r starts with "ok" then
			my dlg("Saves backed up to:" & return & return & my afterBar(r), {"OK"}, "OK")
		else
			my dlg(my afterBar(r), {"OK"}, "OK")
		end if
	else if pick starts with "Force-quit" then
		my core("stop")
		my dlg("Every Windows program in Dungeons for Mac was stopped.", {"OK"}, "OK")
	else if pick starts with "Repair" then
		set b to my dlg("Rebuilds Windows settings and reinstalls the Visual C++ runtimes. Your game files and saves stay where they are.", {"Back", "Repair"}, "Repair")
		if b is "Repair" then
			set res to my runJob("repair", "Repairing the Windows layer")
			my reportResult(res, "Repaired.")
		end if
	else if pick starts with "Minecraft Launcher" then
		my launcherMenu()
	else if pick is "Show log" then
		set r to my core("open-log")
		if r starts with "none" then my dlg("There are no logs yet.", {"OK"}, "OK")
	else if pick starts with "Create a diagnostic" then
		set r to my core("diag")
		if r starts with "ok" then
			my dlg("Saved a report on your Desktop. It contains logs and this Mac's model, no personal files:" & return & return & my afterBar(r), {"OK"}, "OK")
		else
			my dlg(my afterBar(r), {"OK"}, "OK")
		end if
	else if pick starts with "About" then
		my dlg(my aboutText(), {"OK"}, "OK")
	else if pick starts with "Uninstall" then
		if my uninstallFlow() then return "quit"
	else if pick is "Quit" then
		return "quit"
	end if
	return "back"
end moreMenu

on aboutText()
	set v to my valueFor(my core("status"), "version")
	return "Dungeons for Mac " & v & return & return & "Runs the Windows Launcher version of Minecraft Dungeons on Apple silicon." & return & return & "Built on Wine (LGPL), the Highball engine builds of Wine 11 and DXMT, DXMT by 3Shain (MIT), MoltenVK and the Sikarugir runtime. Not affiliated with Mojang or Microsoft." & return & return & "Everything lives in ~/Library/Application Support/DungeonsForMac."
end aboutText

on launcherMenu()
	set statusRaw to my core("status")
	if (my valueFor(statusRaw, "launcher")) is "1" then
		set b to my dlg("The Minecraft Launcher is installed in the Windows layer." & return & return & "1. Open it, sign in and install Minecraft Dungeons." & return & "2. Close the launcher when the download finishes." & return & "3. Come back here and choose Find Installed Game.", {"Back", "Find Installed Game", "Open Launcher"}, "Open Launcher")
		if b is "Open Launcher" then
			set r to my core("launcher-run")
			if r starts with "ok" then
				display notification "Opening the Minecraft Launcher. The first start can take a minute." with title "Dungeons for Mac"
			else
				my dlg(my afterBar(r), {"OK"}, "OK")
			end if
		else if b is "Find Installed Game" then
			set r to my core("find-game")
			if r starts with "ok" then
				my dlg("Found it. Minecraft Dungeons is ready to play.", {"OK"}, "OK")
			else
				my dlg("No installed copy of Minecraft Dungeons was found in the Windows layer yet.", {"OK"}, "OK")
			end if
		end if
	else
		set b to my dlg("Experimental: installs Mojang's Windows Minecraft Launcher inside the Windows layer, so you can try downloading Dungeons straight onto this Mac." & return & return & "It only helps with copies bought on minecraft.net (the Launcher version), and the launcher may not open correctly under Wine. Copying the game from a PC is the reliable way.", {"Back", "Install Launcher"}, "Back")
		if b is "Install Launcher" then
			set res to my runJob("mclauncher", "Installing the Minecraft Launcher")
			my reportResult(res, "Minecraft Launcher installed.")
		end if
	end if
end launcherMenu

on uninstallFlow()
	set b to my dlg("Remove Dungeons for Mac's engine, Windows layer and the copied game?" & return & return & "Your saves live inside it. Back them up to Documents first?", {"Back", "Remove Only", "Back Up and Remove"}, "Back Up and Remove")
	if b is "Back" then return false
	if b is "Back Up and Remove" then
		set r to my core("backup-saves")
		if r starts with "error" then
			my dlg("The backup failed, so nothing was removed:" & return & return & my afterBar(r), {"OK"}, "OK")
			return false
		end if
	end if
	set r to my core("uninstall")
	if r starts with "error" then
		my dlg(my afterBar(r), {"OK"}, "OK")
		return false
	end if
	display dialog "Removed. You can now move the Dungeons for Mac app to the Trash." buttons {"OK"} default button "OK" with title "Dungeons for Mac"
	return true
end uninstallFlow
