#!/bin/bash

# Define the hook path
HOOK_DIR=".git/hooks"
HOOK_FILE="$HOOK_DIR/post-merge"

# 1. Check if we are in a valid git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: .git directory not found."
    echo "   Please run this script from the root of your Git repository."
    exit 1
fi

# 2. Create the hooks directory if it doesn't exist (unlikely in valid repos, but safe)
mkdir -p "$HOOK_DIR"

# 3. Write the hook content
echo "Creating post-merge hook at $HOOK_FILE..."

cat << 'EOF' > "$HOOK_FILE"
#!/bin/bash

# 1. Generate a unique tag name with a timestamp
# Format: backup-pre-pull-YYYYMMDD-HHMMSS
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
TAG_NAME="backup-pre-pull-$TIMESTAMP"

# 2. Check if ORIG_HEAD exists (it should after a merge/pull)
# ORIG_HEAD points to the HEAD commit before the merge/pull occurred
if git rev-parse --verify ORIG_HEAD >/dev/null 2>&1; then
    
    # 3. Create the tag pointing to the pre-pull state
    git tag "$TAG_NAME" ORIG_HEAD
    
    echo "--------------------------------------------------------"
    echo "✅ Backup Successful: Created tag '$TAG_NAME'"
    echo "   To revert to this state, run: git reset --hard $TAG_NAME"
    echo "--------------------------------------------------------"

else
    echo "⚠️  No updates were merged, or ORIG_HEAD is missing. No backup tag created."
fi
EOF

# 4. Make the hook executable
chmod +x "$HOOK_FILE"

echo "✅ Hook installed successfully!"
echo "   Next time you run 'git pull', a backup tag will be created automatically."
