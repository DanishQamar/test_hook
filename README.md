To achieve this, the most reliable method is to use the **`post-merge`** hook.

Although you want to save the state *before* the pull, there is no native `pre-pull` hook in Git. However, whenever a `git pull` (which executes a merge) completes, Git stores the previous commit ID in a special reference called `ORIG_HEAD`.

We can use the `post-merge` hook to create a tag pointing to `ORIG_HEAD` immediately after the pull finishes. This effectively tags the code state as it was right before the changes were applied.

Here is the code to set this up.

### Git Hook Setup

Create the file below inside your `.git/hooks/` directory on the server.

e.g. `YourRepoPath/.git/hooks/post-merge`
To achieve this, the most reliable method is to use the **`post-merge`** hook.

Although you want to save the state *before* the pull, there is no native "pre-pull" hook in Git. However, whenever a `git pull` (which executes a merge) completes, Git automatically stores the specific commit ID of the code *before* the merge in a special reference called `ORIG_HEAD`.

We can use the `post-merge` hook to create a tag pointing to `ORIG_HEAD` immediately after the pull finishes.

### 1. Create the Hook Script

Create (or edit) the file inside your repository's hidden `.git` folder at the path specified below.

**File:** `.git/hooks/post-merge`

```bash
#!/bin/bash

# 1. Generate a unique tag name with a timestamp
# Format: backup-pre-pull-YYYYMMDD-HHMMSS
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
TAG_NAME="backup-pre-pull-$TIMESTAMP"

# 2. Check if ORIG_HEAD exists (it should after a merge/pull)
# ORIG_HEAD points to the HEAD commit before the merge/pull occurred.
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

```

### 2. Make the Hook Executable

Git hooks will not run unless the script has executable permissions. Run this command in your terminal on the server:

```bash
chmod +x .git/hooks/post-merge

```

### 3. How to Revert

When you run `git pull`, you will now see a message confirming the tag creation. If the new code breaks something, you can immediately revert the server to the exact state it was in before the pull using the specific tag name generated:

```bash
git reset --hard backup-pre-pull-20251125-103000

```

> **Note:** This hook works for standard `git pull` operations. If you use `git pull --rebase`, this hook will not trigger (you would need a `pre-rebase` hook for that specific workflow).

Would you like me to provide the `pre-rebase` version as well, in case you use rebase strategies?
