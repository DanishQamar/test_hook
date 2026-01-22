#!/bin/bash

# Define the hook path
HOOK_DIR=".git/hooks"
HOOK_FILE="$HOOK_DIR/pre-push"

# 1. Check if we are in a valid git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: .git directory not found."
    echo "   Please run this script from the root of your Git repository."
    exit 1
fi

# 2. Create the hooks directory if it doesn't exist
mkdir -p "$HOOK_DIR"

# 3. Write the pre-push hook content
echo "Creating pre-push hook at $HOOK_FILE..."

cat << 'EOF' > "$HOOK_FILE"
#!/bin/bash

# This hook blocks all push attempts from this repository
echo "--------------------------------------------------------"
echo "⛔ ACTION BLOCKED: Pushing from this server is disabled."
echo "   This server is configured as a deployment target only."
echo "--------------------------------------------------------"

# Exit with non-zero status to abort the push
exit 1
EOF

# 4. Make the hook executable
chmod +x "$HOOK_FILE"

echo "✅ 'pre-push' hook installed successfully!"
echo "   Any attempt to 'git push' from this server will now be rejected."
