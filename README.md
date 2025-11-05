# Lark Wiki Document Retrieval Script

A comprehensive script to retrieve all documents (including nested ones) from a Lark Wiki using a hybrid approach: Direct API calls + MCP tools.

## Features

- ✅ Recursive traversal of wiki tree structure
- ✅ Automatic discovery of all nested documents
- ✅ Multiple output formats (text, info, JSON)
- ✅ Configurable via simple config section
- ✅ Verbose/debug mode support
- ✅ Error handling and logging

## Configuration

Edit the configuration section at the top of the script:

```bash
# Lark API Configuration
APP_ID="your_app_id"
APP_SECRET="your_app_secret"
SPACE_ID="your_space_id"

# Root Node Tokens (extract from wiki URLs)
declare -a ROOT_NODES=(
  "NODE_TOKEN_1|Title 1"
  "NODE_TOKEN_2|Title 2"
  "NODE_TOKEN_3|Title 3"
)

# Output Configuration
OUTPUT_DIR="./temp"
OUTPUT_FILE="$OUTPUT_DIR/wiki_documents_complete.txt"
INFO_FILE="$OUTPUT_DIR/wiki_documents_info.txt"
JSON_FILE="$OUTPUT_DIR/wiki_documents.json"

# Options
VERBOSE=false  # Set to true for debug output
INCLUDE_CONTENT=true  # Set to false to skip content retrieval
```

## Usage

1. **Get your Lark credentials:**
   - App ID and App Secret from Lark Open Platform
   - Space ID from your wiki space

2. **Extract root node tokens:**
   - Open each root wiki page
   - Extract token from URL: `https://...larksuite.com/wiki/{TOKEN}`

3. **Configure the script:**
   - Edit the configuration section
   - Add all root node tokens

4. **Run the script:**
   ```bash
   chmod +x get_all_wiki_docs.sh
   ./get_all_wiki_docs.sh
   ```

## Output Files

The script generates three output files:

1. **`wiki_documents_complete.txt`** - Full text report with all document details
2. **`wiki_documents_info.txt`** - Structured info report with tree view
3. **`wiki_documents.json`** - JSON format for programmatic use

## How It Works

1. **Authentication**: Gets tenant access token using App ID/Secret
2. **Traversal**: Recursively traverses wiki tree from root nodes
3. **Collection**: Collects all document tokens and metadata
4. **Reporting**: Generates multiple output formats

## Requirements

- `bash` (4.0+)
- `curl`
- `python3`
- Valid Lark API credentials

## Troubleshooting

**Error: "Failed to get tenant token"**
- Check your APP_ID and APP_SECRET
- Verify credentials in Lark Open Platform

**Error: "permission denied"**
- Ensure your app has wiki read permissions
- Check space ID is correct

**Missing nested documents**
- Verify root node tokens are correct
- Check if nodes have children (has_child flag)
- Enable VERBOSE=true to see debug output

## Example Output

```
📄 [1] Welcome to Wiki
📄 [2] Administrator Manual
│  📄 [2.1] Create workspace
│  📄 [2.2] Manage members
📄 [3] Member Manual
│  📄 [3.1] Enter a workspace
│  📄 [3.2] Team collaboration
│  📄 [3.3] Add pages
│  📄 [3.4] Access permissions
│  📄 [3.5] FAQs

Total Documents: 10
Root Documents: 3
Nested Documents: 7
```

## Notes

- Content retrieval currently uses placeholder (set `INCLUDE_CONTENT=false` to skip)
- For actual content retrieval, integrate with MCP tools (docx.v1.document.rawContent)
- The script handles unlimited nesting depth automatically

