#!/bin/bash

# Define hook paths
HOOK_DIR=".git/hooks"
POST_MERGE_FILE="$HOOK_DIR/post-merge"
PRE_PUSH_FILE="$HOOK_DIR/pre-push"

# 1. Check if we are in a valid git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: .git directory not found."
    echo "   Please run this script from the root of your Git repository."
    exit 1
fi

mkdir -p "$HOOK_DIR"

# ==========================================
# 2. Create 'post-merge' hook (Backup Tags)
# ==========================================
echo "Installing post-merge hook (Auto-Tagging)..."

cat << 'EOF' > "$POST_MERGE_FILE"
#!/bin/bash

# 1. Generate a shared timestamp for both tags
# Format: YYYYMMDD-HHMMSS
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# Define Tag Names
TAG_PRE="backup-pull-$TIMESTAMP-0-pre-tag"
TAG_POST="backup-pull-$TIMESTAMP-1-post-tag"

# 2. Check if ORIG_HEAD exists (Standard check for a merge/pull)
if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
    
    # Tag the state BEFORE the pull (ORIG_HEAD)
    git tag "$TAG_PRE" ORIG_HEAD
    
    # Tag the state AFTER the pull (Current HEAD)
    git tag "$TAG_POST" HEAD
    
    echo "--------------------------------------------------------"
    echo "✅ Backup Tags Created:"
    echo "   1. Before Pull: $TAG_PRE"
    echo "   2. After  Pull: $TAG_POST"
    echo "--------------------------------------------------------"

else
    echo "⚠️  No updates merged or ORIG_HEAD missing. No tags created."
fi
EOF

# Make executable
chmod +x "$POST_MERGE_FILE"


# ==========================================
# 3. Create 'pre-push' hook (Block Pushes)
# ==========================================
echo "Installing pre-push hook (Push Blocker)..."

cat << 'EOF' > "$PRE_PUSH_FILE"
#!/bin/bash

# Block pushes unless --no-verify is used
echo "--------------------------------------------------------"
echo "⛔ ACTION BLOCKED: Pushing from this server is disabled."
echo "   This server is configured as a deployment target only."
echo "   (Use 'git push --no-verify' if you strictly need to bypass)"
echo "--------------------------------------------------------"
exit 1
EOF

# Make executable
chmod +x "$PRE_PUSH_FILE"


# ==========================================
# 4. Final Confirmation
# ==========================================
echo "✅ Setup Complete!"
echo "   - Auto-tagging enabled for 'git pull' (Pre & Post tags)."
echo "   - 'git push' is now disabled on this server."
