#!/bin/bash
# Sourced. Without Xcode's macros and sourcekitd, harnesses and SwiftLint fail like broken code.
case "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}" in
    */CommandLineTools*|"")
        echo "✗ This needs Xcode's toolchain; the active developer directory is the Command Line Tools." >&2
        echo "  Switch once:  sudo xcode-select -s /Applications/Xcode.app" >&2
        echo "  or per run:   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0" >&2
        exit 2
        ;;
esac
