#!/usr/bin/osascript
on run arguments
    repeat with filename in arguments
        set filealias to POSIX file filename
        tell application "iTunes"
            add filealias to library playlist 1
        end tell
    end repeat
end run
