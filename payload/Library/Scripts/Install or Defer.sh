#!/bin/bash

###
#
#            Name:  Install or Defer.sh
#     Description:  This script, meant to be triggered periodically by a
#                   LaunchDaemon, will prompt users to install Apple system
#                   updates that the IT department has deemed "critical." Users
#                   will have the option to Run Updates or Defer. After a
#                   specified amount of time, the update will be forced. If
#                   updates requiring a restart were found in the update check,
#                   the system restarts automatically.
#         Authors:  Mario Panighetti and Elliot Jordan
#         Created:  2017-03-09
#   Last Modified:  2020-07-06
#         Version:  3.0.2
#
###


########################## FILE PATHS AND IDENTIFIERS #########################

# Path to a plist file that is used to store settings locally. Omit ".plist"
# extension.
PLIST="/Library/Preferences/com.github.mpanighetti.install-or-defer"

# (Optional) Path to a logo that will be used in messaging. Recommend 512px,
# PNG format. If no logo is provided, the Software Update icon will be used.
LOGO=""

# The identifier of the LaunchDaemon that is used to call this script, which
# should match the file in the payload/Library/LaunchDaemons folder. Omit
# ".plist" extension.
BUNDLE_ID="com.github.mpanighetti.install-or-defer"

# The file path of this script.
SCRIPT_PATH="/Library/Scripts/Install or Defer.sh"


################################## MESSAGING ##################################

# The messages below use the following dynamic substitutions:
#   - %DEFER_HOURS% will be automatically replaced by the number of hours
#     remaining in the deferral period.
#   - The section in the {{double curly brackets}} will be removed when this
#     message is displayed for the final time before the deferral deadline.
#   - The sections in the <<double comparison operators>> will be removed if a restart
#     is not required for the pending updates.
#   - %UPDATE_MECHANISM% will be automatically replaced depending on macOS
#     version:
#     - macOS 10.13 or lower: "App Store - Updates"
#     - macOS 10.14+: "System Preferences - Software Update"

# The message users will receive when updates are available, shown above the
# "Run Updates" and "Defer" buttons.
MSG_ACT_OR_DEFER_HEADING="Critical updates are available"
MSG_ACT_OR_DEFER="Apple has released critical security updates, and your IT department would like you to install them as soon as possible. Please save your work, quit all applications, and click Run Updates.

{{If now is not a good time, you may defer this message until later. }}Updates will install automatically after %DEFER_HOURS% hours<<, forcing your Mac to restart in the process>>. Note: This may result in losing unsaved work.

If you'd like to manually install the updates yourself, open %UPDATE_MECHANISM% and apply all system and security updates<<, then restart when prompted>>.

If you have any questions, please call or email the IT help desk."

# The message users will receive after the deferral deadline has been reached.
MSG_ACT_HEADING="Please run updates now"
MSG_ACT="Please save your work, then open %UPDATE_MECHANISM% and apply all system and security updates<<, then restart when prompted>>. If no action is taken, updates will be installed automatically<<, and your Mac will restart>>."

# The message users will receive while updates are running in the background.
MSG_UPDATING_HEADING="Running updates"
MSG_UPDATING="Running system updates in the background.<< Your Mac will restart automatically when this is finished.>> You can force this to complete sooner by opening %UPDATE_MECHANISM% and applying all system and security updates."


#################################### TIMING ###################################

# Number of seconds between the first script run and the updates being forced.
MAX_DEFERRAL_TIME=$(( 60 * 60 * 24 * 3 )) # (259200 = 3 days)

# When the user clicks "Defer" the next prompt is delayed by this much time.
EACH_DEFER=$(( 60 * 60 * 4 )) # (14400 = 4 hours)

# The number of seconds to wait between displaying the "run updates" message
# and applying updates, then attempting a soft restart.
UPDATE_DELAY=$(( 60 * 10 )) # (600 = 10 minutes)

# The number of seconds to wait between attempting a soft restart and forcing a
# restart.
HARD_RESTART_DELAY=$(( 60 * 5 )) # (300 = 5 minutes)


################################## FUNCTIONS ##################################

# Takes a number of seconds as input and returns hh:mm:ss format.
# Source: http://stackoverflow.com/a/12199798
# License: CC BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/)
# Created by: perreal (http://stackoverflow.com/users/390913/perreal)
convert_seconds () {

    if [[ $1 -eq 0 ]]; then
        HOURS=0
        MINUTES=0
        SECONDS=0
    else
        ((HOURS=${1}/3600))
        ((MINUTES=(${1}%3600)/60))
        ((SECONDS=${1}%60))
    fi
    printf "%02dh:%02dm:%02ds\n" "$HOURS" "$MINUTES" "$SECONDS"

}

# Caches all available critical system updates, or exits if no critical updates
# are available.
check_for_updates () {

    echo "Checking for pending system updates..."
    UPDATE_CHECK=$(/usr/sbin/softwareupdate --list 2>&1)

    # Determine whether any critical updates are available, and if any require
    # a restart. If no updates need to be installed, bail out.
    if [[ "$UPDATE_CHECK" =~ (Action: restart|\[restart\]) ]]; then
        INSTALL_WHICH="all"
        # Remove "<<" and ">>" but leave the text between
        # (retains restart warnings).
        MSG_ACT_OR_DEFER="$(echo "$MSG_ACT_OR_DEFER" | /usr/bin/sed 's/[\<\<|\>\>]//g')"
        MSG_ACT="$(echo "$MSG_ACT" | /usr/bin/sed 's/[\<\<|\>\>]//g')"
        MSG_UPDATING="$(echo "$MSG_UPDATING" | /usr/bin/sed 's/[\<\<|\>\>]//g')"
    elif [[ "$UPDATE_CHECK" =~ (Recommended: YES|\[recommended\]) ]]; then
        INSTALL_WHICH="recommended"
        # Remove "<<" and ">>" including all the text between
        # (removes restart warnings).
        MSG_ACT_OR_DEFER="$(echo "$MSG_ACT_OR_DEFER" | /usr/bin/sed 's/\<\<.*\>\>//g')"
        MSG_ACT="$(echo "$MSG_ACT" | /usr/bin/sed 's/\<\<.*\>\>//g')"
        MSG_UPDATING="$(echo "$MSG_UPDATING" | /usr/bin/sed 's/\<\<.*\>\>//g')"
    else
        echo "No critical updates available."
        exit_without_updating
    fi

    # Download updates (all updates if a restart is required for any, otherwise
    # just recommended updates).
    echo "Caching $INSTALL_WHICH system updates..."
    /usr/sbin/softwareupdate --download --$INSTALL_WHICH --no-scan

}

# Displays an onscreen message instructing the user to apply updates.
# This function is invoked after the deferral deadline passes.
display_act_msg () {

    # Create a jamfHelper script that will be called by a LaunchDaemon.
    /bin/cat << EOF > "$HELPER_SCRIPT"
#!/bin/bash
"$JAMFHELPER" -windowType "utility" -windowPosition "ur" -icon "$LOGO" -title "$MSG_ACT_HEADING" -description "$MSG_ACT"
EOF
    /bin/chmod +x "$HELPER_SCRIPT"

    # Create the LaunchDaemon that we'll use to show the persistent jamfHelper
    # messages.
    /bin/cat << EOF > "$HELPER_LD"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>${BUNDLE_ID}_helper</string>
	<key>Program</key>
	<string>$HELPER_SCRIPT</string>
	<key>ThrottleInterval</key>
	<integer>10</integer>
</dict>
</plist>
EOF

    # Load the LaunchDaemon to show the jamfHelper message.
    echo "Displaying \"run updates\" message..."
    /usr/bin/killall jamfHelper 2>"/dev/null"
    /bin/launchctl load -w "$HELPER_LD"

    # After specified delay, apply updates.
    echo "Waiting $(( UPDATE_DELAY / 60 )) minutes before automatically applying updates..."
    /bin/sleep "$UPDATE_DELAY"
    echo "$(( UPDATE_DELAY / 60 )) minutes have elapsed since user was prompted to run updates. Triggering updates..."

    /bin/launchctl unload "$HELPER_LD"

    run_updates

}

# Displays HUD with updating message and runs all security updates (as defined
# by previous checks).
run_updates () {

    # Display HUD with updating message.
    "$JAMFHELPER" -windowType "hud" -windowPosition "ur" -icon "$LOGO" -title "$MSG_UPDATING_HEADING" -description "$MSG_UPDATING" -lockHUD &

    # Run Apple system updates.
    echo "Running $INSTALL_WHICH Apple system updates..."
    UPDATE_OUTPUT_CAPTURE="$(/usr/sbin/softwareupdate --install --$INSTALL_WHICH --no-scan 2>&1)"
    echo "Finished running Apple updates."

    # Trigger restart if script found an update which requires it.
    if [[ "$INSTALL_WHICH" = "all" ]]; then
        # Shut down the Mac if BridgeOS received an update requiring it.
        if [[ "$UPDATE_OUTPUT_CAPTURE" == *"select Shut Down from the Apple menu"* ]]; then
            trigger_restart "shut down"
        # Otherwise, restart the Mac.
        else
            trigger_restart "restart"
        fi
    fi

    clean_up

}

# Initializes plist values and moves all script and LaunchDaemon resources to
# /private/tmp for deletion on a subsequent restart.
clean_up () {

    echo "Killing any active jamfHelper notifications..."
    /usr/bin/killall jamfHelper 2>"/dev/null"

    echo "Cleaning up stored plist values..."
    /usr/bin/defaults delete "$PLIST" 2>"/dev/null"

    echo "Cleaning up script resources..."
    CLEANUP_FILES=(
        "/Library/LaunchDaemons/$BUNDLE_ID.plist"
        "$HELPER_LD"
        "$HELPER_SCRIPT"
        "$SCRIPT_PATH"
    )
    CLEANUP_DIR="/private/tmp/install-or-defer"
    /bin/mkdir "$CLEANUP_DIR"
    for TARGET_FILE in "${CLEANUP_FILES[@]}"; do
        if [[ -e "$TARGET_FILE" ]]; then
            /bin/mv -v "$TARGET_FILE" "$CLEANUP_DIR"
        fi
    done
    if [[ $(/bin/launchctl list) == *"${BUNDLE_ID}_helper"* ]]; then
        echo "Unloading ${BUNDLE_ID}_helper LaunchDaemon..."
        /bin/launchctl remove "${BUNDLE_ID}_helper"
    fi

}

# Restarts or shuts down the system depending on parameter input. Attempts a
# "soft" restart, waits a specified amount of time, and then forces a "hard"
# restart.
trigger_restart () {

    clean_up

    # Immediately attempt a "soft" restart.
    echo "Attempting a \"soft\" $1..."
    CURRENT_USER=$(/usr/bin/stat -f%Su /dev/console)
    USER_ID=$(/usr/bin/id -u "$CURRENT_USER")
    /bin/launchctl asuser "$USER_ID" osascript -e "tell application \"System Events\" to $1"

    # After specified delay, kill all apps forcibly, which clears the way for
    # an unobstructed restart.
    echo "Waiting $(( HARD_RESTART_DELAY / 60 )) minutes before forcing a \"hard\" $1..."
    /bin/sleep "$HARD_RESTART_DELAY"
    echo "$(( HARD_RESTART_DELAY / 60 )) minutes have elapsed since \"soft\" $1 was attempted. Forcing \"hard\" $1..."

    USER_PIDS=$(pgrep -u "$USER_ID")
    LOGINWINDOW_PID=$(pgrep -x -u "$USER_ID" loginwindow)
    for PID in $USER_PIDS; do
        # Kill all processes except the loginwindow process.
        if [[ "$PID" -ne "$LOGINWINDOW_PID" ]]; then
            kill -9 "$PID"
        fi
    done
    /bin/launchctl asuser "$USER_ID" osascript -e "tell application \"System Events\" to $1"
    # Mac should restart now, ending this script and installing updates.

}

# Ends script without applying any security updates.
exit_without_updating () {

    echo "Updating Jamf Pro inventory..."
    "$JAMF_BINARY" recon

    clean_up

    # Unload main LaunchDaemon. This will likely kill the script.
    if [[ $(/bin/launchctl list) == *"$BUNDLE_ID"* ]]; then
        echo "Unloading $BUNDLE_ID LaunchDaemon..."
        /bin/launchctl remove "$BUNDLE_ID"
    fi
    echo "Script will end here."
    exit 0

}


######################## VALIDATION AND ERROR CHECKING ########################

# Copy all output to the system log for diagnostic purposes.
exec 1> >(/usr/bin/logger -s -t "$(/usr/bin/basename "$0")") 2>&1
echo "Starting $(/usr/bin/basename "$0") script. Performing validation and error checking..."

# Define custom $PATH.
PATH="/usr/sbin:/usr/bin:/usr/local/bin:$PATH"

# Filename and path we will use for the auto-generated helper script and LaunchDaemon.
HELPER_SCRIPT="/Library/Scripts/$(/usr/bin/basename "$0" | /usr/bin/sed "s/.sh$//g")_helper.sh"
HELPER_LD="/Library/LaunchDaemons/${BUNDLE_ID}_helper.plist"

# Flag variable for catching show-stopping errors.
BAILOUT=false

# Bail out if the jamfHelper doesn't exist.
JAMFHELPER="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
if [[ ! -x "$JAMFHELPER" ]]; then
    echo "❌ ERROR: The jamfHelper binary must be present in order to run this script."
    BAILOUT=true
fi

# Bail out if the jamf binary doesn't exist.
JAMF_BINARY="/usr/local/bin/jamf"
if [[ ! -e "$JAMF_BINARY" ]]; then
    echo "❌ ERROR: The jamf binary could not be found."
    BAILOUT=true
fi

# Determine macOS version.
OS_MAJOR=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F . '{print $1}')
OS_MINOR=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F . '{print $2}')

# If the macOS version is not 10.13 through 10.15, this script may not work.
# When new versions of macOS are released, this logic should be updated after
# the script has been tested successfully.
if [[ "$OS_MAJOR" -eq 10 && "$OS_MINOR" -lt 13 ]] || [[ "$OS_MAJOR" -lt 10 ]]; then
    echo "❌ ERROR: This script requires at least macOS 10.13. This Mac has $OS_MAJOR.$OS_MINOR."
    BAILOUT=true
elif [[ "$OS_MAJOR" -gt 10 ]] || [[ "$OS_MINOR" -gt 15 ]]; then
    echo "❌ ERROR: This script has been tested through macOS 10.15 only. This Mac has $OS_MAJOR.$OS_MINOR."
    BAILOUT=true
else
    if [[ "$OS_MINOR" -lt 14 ]]; then
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER//%UPDATE_MECHANISM%/App Store - Updates}"
        MSG_ACT="${MSG_ACT//%UPDATE_MECHANISM%/App Store - Updates}"
        MSG_UPDATING="${MSG_UPDATING//%UPDATE_MECHANISM%/App Store - Updates}"
    else
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER//%UPDATE_MECHANISM%/System Preferences - Software Update}"
        MSG_ACT="${MSG_ACT//%UPDATE_MECHANISM%/System Preferences - Software Update}"
        MSG_UPDATING="${MSG_UPDATING//%UPDATE_MECHANISM%/System Preferences - Software Update}"
    fi
fi

# We need to be connected to the internet in order to download updates.
if /sbin/ping -q -c 1 208.67.222.222; then
    # Check if a custom CatalogURL is set and if it is available
    # (deprecated in macOS 11+).
    if [[ "$OS_MAJOR" -eq 10 && "$OS_MINOR" -lt 16 ]]; then
        SU_CATALOG=$(/usr/bin/defaults read "/Library/Managed Preferences/com.apple.SoftwareUpdate" CatalogURL 2>"/dev/null")
        if [[ "$SU_CATALOG" != "None" ]]; then
            if /usr/bin/curl --user-agent "Darwin/$(/usr/bin/uname -r)" -s --head "$SU_CATALOG" | /usr/bin/grep "200 OK" >"/dev/null"; then
                echo "❌ ERROR: Software update catalog can not be reached."
                BAILOUT=true
            fi
        fi
    fi
else
    echo "❌ ERROR: No connection to the Internet."
    BAILOUT=true
fi

# If FileVault encryption or decryption is in progress, installing updates that
# require a restart can cause problems.
if /usr/bin/fdesetup status | /usr/bin/grep -q "in progress"; then
    echo "❌ ERROR: FileVault encryption or decryption is in progress."
    BAILOUT=true
fi

# If any of the errors above are present, bail out of the script now.
if [[ "$BAILOUT" = "true" ]]; then
    # Checks for StartInterval definition in LaunchDaemon.
    START_INTERVAL=$(/usr/bin/defaults read "/Library/LaunchDaemons/$BUNDLE_ID.plist" StartInterval 2>"/dev/null")
    if [[ -n "$START_INTERVAL" ]]; then
        echo "Stopping due to errors, but will try again in $(convert_seconds "$START_INTERVAL")."
    else
        echo "Stopping due to errors."
    fi
    exit 1
else
    echo "Validation and error checking passed. Starting main process..."
fi


################################ MAIN PROCESS #################################

# Validate logo file. If no logo is provided or if the file cannot be found at
# specified path, default to the Software Update icon.
if [[ -z "$LOGO" ]] || [[ ! -f "$LOGO" ]]; then
    echo "No logo provided, or no logo exists at specified path. Using Software Update icon."
    LOGO="/System/Library/CoreServices/Software Update.app/Contents/Resources/SoftwareUpdate.icns"
fi

# Validate max deferral time and whether to skip deferral. To customize these
# values, make a configuration profile enforcing the MaxDeferralTime (in
# seconds) and SkipDeferral (boolean) attributes in $BUNDLE_ID to settings of
# your choice.
SKIP_DEFERRAL=$(/usr/bin/defaults read "/Library/Managed Preferences/$BUNDLE_ID" SkipDeferral 2>"/dev/null")
if [[ "$SKIP_DEFERRAL" = "True" ]]; then
    MAX_DEFERRAL_TIME=0
else
    MAX_DEFERRAL_TIME_CUSTOM=$(/usr/bin/defaults read "/Library/Managed Preferences/$BUNDLE_ID" MaxDeferralTime 2>"/dev/null")
    if (( MAX_DEFERRAL_TIME_CUSTOM > 0 )); then
        MAX_DEFERRAL_TIME="$MAX_DEFERRAL_TIME_CUSTOM"
    else
        echo "Max deferral time undefined, or not set to a positive integer. Using default value."
    fi
fi
echo "Maximum deferral time: $(convert_seconds "$MAX_DEFERRAL_TIME")"

# Perform first run tasks, including calculating deadline.
FORCE_DATE=$(/usr/bin/defaults read "$PLIST" AppleSoftwareUpdatesForcedAfter 2>"/dev/null")
if [[ -z $FORCE_DATE || $FORCE_DATE -gt $(( $(/bin/date +%s) + MAX_DEFERRAL_TIME )) ]]; then
    FORCE_DATE=$(( $(/bin/date +%s) + MAX_DEFERRAL_TIME ))
    /usr/bin/defaults write "$PLIST" AppleSoftwareUpdatesForcedAfter -int $FORCE_DATE
fi

# Calculate how much time remains until deferral deadline.
DEFER_TIME_LEFT=$(( FORCE_DATE - $(/bin/date +%s) ))
echo "Deferral deadline: $(/bin/date -jf "%s" "+%Y-%m-%d %H:%M:%S" "$FORCE_DATE")"
echo "Time remaining: $(convert_seconds $DEFER_TIME_LEFT)"

# Get the "deferred until" timestamp, if one exists.
DEFERRED_UNTIL=$(/usr/bin/defaults read "$PLIST" AppleSoftwareUpdatesDeferredUntil 2>"/dev/null")
if [[ -n "$DEFERRED_UNTIL" ]] && (( DEFERRED_UNTIL > $(/bin/date +%s) && FORCE_DATE > DEFERRED_UNTIL )); then
    # If the policy ran recently and was deferred, we need to respect that
    # "defer until" timestamp, as long as it is earlier than the deferral
    # deadline.
    echo "The next prompt is deferred until after $(/bin/date -jf "%s" "+%Y-%m-%d %H:%M:%S" "$DEFERRED_UNTIL")."
    exit 0
fi

# Check for updates, exit if none found, otherwise cache locally and continue.
check_for_updates

# Make a note of the time before displaying the prompt.
PROMPT_START=$(/bin/date +%s)

# If defer time remains, display the prompt. If not, install and restart.
if (( DEFER_TIME_LEFT > 0 )); then

    # Substitute the correct number of hours remaining.
    if (( DEFER_TIME_LEFT > 7200 )); then
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER//%DEFER_HOURS%/$(( DEFER_TIME_LEFT / 3600 ))}"
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER// 1 hours/ 1 hour}"
    elif (( DEFER_TIME_LEFT > 60 )); then
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER//%DEFER_HOURS% hours/$(( DEFER_TIME_LEFT / 60 )) minutes}"
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER// 1 minutes/ 1 minute}"
    else
        MSG_ACT_OR_DEFER="${MSG_ACT_OR_DEFER//after %DEFER_HOURS% hours/very soon}"
    fi

    # Determine whether to include the "you may defer" wording.
    if (( EACH_DEFER > DEFER_TIME_LEFT )); then
        # Remove "{{" and "}}" including all the text between.
        MSG_ACT_OR_DEFER="$(echo "$MSG_ACT_OR_DEFER" | /usr/bin/sed 's/{{.*}}//g')"
    else
        # Just remove "{{" and "}}" but leave the text between.
        MSG_ACT_OR_DEFER="$(echo "$MSG_ACT_OR_DEFER" | /usr/bin/sed 's/[{{|}}]//g')"
    fi

    # Show the install/defer prompt.
    echo "Prompting to install updates now or defer..."
    PROMPT=$("$JAMFHELPER" -windowType "utility" -windowPosition "ur" -icon "$LOGO" -title "$MSG_ACT_OR_DEFER_HEADING" -description "$MSG_ACT_OR_DEFER" -button1 "Run Updates" -button2 "Defer" -defaultButton 2 -timeout 3600 -startlaunchd 2>"/dev/null")
    JAMFHELPER_PID=$!

    # Make a note of the amount of time the prompt was shown onscreen.
    PROMPT_END=$(/bin/date +%s)
    PROMPT_ELAPSED_SEC=$(( PROMPT_END - PROMPT_START ))

    # Generate a duration string that will be used in log output.
    if [[ -n $PROMPT_ELAPSED_SEC && $PROMPT_ELAPSED_SEC -eq 0 ]]; then
        PROMPT_ELAPSED_STR="immediately"
    elif [[ -n $PROMPT_ELAPSED_SEC ]]; then
        PROMPT_ELAPSED_STR="after $(convert_seconds "$PROMPT_ELAPSED_SEC")"
    elif [[ -z $PROMPT_ELAPSED_SEC ]]; then
        PROMPT_ELAPSED_STR="after an unknown amount of time"
        echo "[WARNING] Unable to determine elapsed time between prompt and action."
    fi

    # For reference, here is a list of the possible jamfHelper return codes:
    # https://gist.github.com/homebysix/18c1a07a284089e7f279#file-jamfhelper_help-txt-L72-L84

    # Take action based on the return code of the jamfHelper.
    if [[ -n $PROMPT && $PROMPT_ELAPSED_SEC -eq 0 ]]; then
        # Kill the jamfHelper prompt.
        kill -9 $JAMFHELPER_PID
        echo "❌ ERROR: jamfHelper returned code $PROMPT $PROMPT_ELAPSED_STR. It's unlikely that the user responded that quickly."
        exit 1
    elif [[ -n $PROMPT && $DEFER_TIME_LEFT -gt 0 && $PROMPT -eq 0 ]]; then
        echo "User clicked Run Updates $PROMPT_ELAPSED_STR."
        /usr/bin/defaults delete "$PLIST" AppleSoftwareUpdatesDeferredUntil 2>"/dev/null"
        run_updates
    elif [[ -n $PROMPT && $DEFER_TIME_LEFT -gt 0 && $PROMPT -eq 1 ]]; then
        # Kill the jamfHelper prompt.
        kill -9 $JAMFHELPER_PID
        echo "❌ ERROR: jamfHelper was not able to launch $PROMPT_ELAPSED_STR."
        exit 1
    elif [[ -n $PROMPT && $DEFER_TIME_LEFT -gt 0 && $PROMPT -eq 2 ]]; then
        echo "User clicked Defer $PROMPT_ELAPSED_STR."
        NEXT_PROMPT=$(( $(/bin/date +%s) + EACH_DEFER ))
        /usr/bin/defaults write "$PLIST" AppleSoftwareUpdatesDeferredUntil -int "$NEXT_PROMPT"
        echo "Next prompt will appear after $(/bin/date -jf "%s" "+%Y-%m-%d %H:%M:%S" "$NEXT_PROMPT")."
    elif [[ -n $PROMPT && $DEFER_TIME_LEFT -gt 0 && $PROMPT -eq 239 ]]; then
        echo "User deferred by exiting jamfHelper $PROMPT_ELAPSED_STR."
        NEXT_PROMPT=$(( $(/bin/date +%s) + EACH_DEFER ))
        /usr/bin/defaults write "$PLIST" AppleSoftwareUpdatesDeferredUntil -int "$NEXT_PROMPT"
        echo "Next prompt will appear after $(/bin/date -jf "%s" "+%Y-%m-%d %H:%M:%S" "$NEXT_PROMPT")."
    elif [[ -n $PROMPT && $DEFER_TIME_LEFT -gt 0 && $PROMPT -gt 2 ]]; then
        # Kill the jamfHelper prompt.
        kill -9 $JAMFHELPER_PID
        echo "❌ ERROR: jamfHelper produced an unexpected value (code $PROMPT) $PROMPT_ELAPSED_STR."
        exit 1
    elif [[ -z $PROMPT ]]; then # $PROMPT is not defined
        # Kill the jamfHelper prompt.
        kill -9 $JAMFHELPER_PID
        echo "❌ ERROR: jamfHelper returned no value $PROMPT_ELAPSED_STR. Run Updates/Defer response was not captured. This may be because the user logged out without clicking Run Updates/Defer."
        exit 1
    else
        # Kill the jamfHelper prompt.
        kill -9 $JAMFHELPER_PID
        echo "❌ ERROR: Something went wrong. Check the jamfHelper return code ($PROMPT) and prompt elapsed seconds ($PROMPT_ELAPSED_SEC) for further information."
        exit 1
    fi

else
    # If no deferral time remains, force installation of updates now.
    echo "No deferral time remains."
    display_act_msg
fi

exit 0
