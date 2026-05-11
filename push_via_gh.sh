#!/bin/bash
set -e

REPO="xianren839-lang/legado-stv"

# Get remote HEAD sha and tree
BASE_SHA=$(gh api repos/$REPO/git/refs/heads/master --jq '.object.sha')
echo "Remote HEAD: $BASE_SHA"

# Collect commit messages
MSG=$(git log origin/master..HEAD --reverse --format='%s')
COMMIT_MSG=$(echo "$MSG" | head -1)
echo "Commits: $(echo "$MSG" | wc -l)"

# Get changed files between origin/master and HEAD
CHANGED_FILES=$(git diff --name-status origin/master HEAD)
echo "Changed files:"
echo "$CHANGED_FILES"

# Step 1: Create blobs for each changed file
TREE_ITEMS="[]"

while IFS=$'\t' read -r STATUS FILE; do
    if [ "$STATUS" = "D" ]; then
        echo "  Deleted: $FILE"
        ITEM=$(jq -n --arg path "$FILE" '{"path": $path, "mode": "100644", "type": "blob", "sha": "4b825dc642cb6eb9a060e54bf899d69f0f12345"}')
        TREE_ITEMS=$(echo "$TREE_ITEMS" | jq --argjson item "$ITEM" '. + [$item]')
    else
        FILE_PATH="$(git rev-parse --show-toplevel)/$FILE"

        if [ ! -f "$FILE_PATH" ]; then
            echo "  SKIP (not found): $FILE"
            continue
        fi

        # base64 encode the file
        CONTENT_B64=$(base64 -w 0 < "$FILE_PATH" 2>/dev/null || base64 < "$FILE_PATH" | tr -d '\r\n')

        # Create blob via API
        BLOB_SHA=$(gh api repos/$REPO/git/blobs \
            -X POST \
            -f content="$CONTENT_B64" \
            -f encoding="base64" \
            --jq '.sha' 2>&1) || {
            echo "  FAILED blob for $FILE: $BLOB_SHA"
            continue
        }

        echo "  Blob: $STATUS $FILE -> $BLOB_SHA"

        # Get file mode
        MODE="100644"
        if [ -x "$FILE_PATH" ]; then MODE="100755"; fi

        ITEM=$(jq -n --arg path "$FILE" --arg mode "$MODE" --arg sha "$BLOB_SHA" \
            '{"path": $path, "mode": $mode, "type": "blob", "sha": $sha}')
        TREE_ITEMS=$(echo "$TREE_ITEMS" | jq --argjson item "$ITEM" '. + [$item]')
    fi
done <<< "$CHANGED_FILES"

echo "---"
echo "Tree items count: $(echo "$TREE_ITEMS" | jq 'length')"

# Step 2: Create tree (modify base tree)
TREE_JSON=$(jq -n --arg base_tree "$(gh api repos/$REPO/git/commits/$BASE_SHA --jq '.tree.sha')" --argjson tree "$TREE_ITEMS" \
    '{"base_tree": $base_tree, "tree": $tree}')

echo "Creating tree..."
TREE_SHA=$(gh api repos/$REPO/git/trees \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$TREE_JSON" \
    --jq '.sha')
echo "Tree SHA: $TREE_SHA"

# Step 3: Create commit
COMMIT_JSON=$(jq -n --arg message "$COMMIT_MSG" --arg tree "$TREE_SHA" --arg parent "$BASE_SHA" \
    '{"message": $message, "tree": $tree, "parents": [$parent]}')

echo "Creating commit..."
NEW_SHA=$(gh api repos/$REPO/git/commits \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$COMMIT_JSON" \
    --jq '.sha')
echo "New commit SHA: $NEW_SHA"

# Step 4: Update ref
echo "Updating master ref..."
gh api repos/$REPO/git/refs/heads/master \
    -X PATCH \
    -f sha="$NEW_SHA" \
    -f force="true"

echo "=== Push complete! ==="
