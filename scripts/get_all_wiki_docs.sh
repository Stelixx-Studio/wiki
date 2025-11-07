#!/bin/bash

################################################################################
# Lark Wiki Document Retrieval Script
# Retrieves all documents (including nested) from a Lark Wiki
# Uses Server API only: Direct API calls for structure and content
################################################################################

set +e  # Don't exit on error - continue processing all documents

################################################################################
# CONFIGURATION LOADING
################################################################################

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Change to project root directory
cd "$PROJECT_ROOT"

# Load sensitive credentials from .env file (if exists)
# Note: LARK_ROOT_NODES should come from environment variables (GitHub Secrets) first
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# Map LARK_* variables to script variables
# Prioritize environment variables (from GitHub Actions) over .env file
APP_ID="${LARK_APP_ID}"
APP_SECRET="${LARK_APP_SECRET}"
SPACE_ID="${LARK_SPACE_ID}"

# Parse root nodes from environment variable (set by GitHub Actions from secrets)
# Support both comma-separated and JSON array formats for backward compatibility
declare -a ROOT_NODES=()

if [ -n "${LARK_ROOT_NODES}" ]; then
  # Check if it's JSON array format (starts with [)
  if [[ "${LARK_ROOT_NODES}" =~ ^\[.*\]$ ]]; then
    # JSON array format (backward compatibility)
    ROOT_NODES_ARRAY=$(echo "${LARK_ROOT_NODES}" | python3 -c "
import sys, json
try:
    tokens = json.load(sys.stdin)
    for token in tokens:
        print(token)
except:
    pass
" 2>/dev/null)
    while IFS= read -r token; do
      if [ -n "$token" ]; then
        ROOT_NODES+=("$token")
      fi
    done <<< "$ROOT_NODES_ARRAY"
  else
    # Comma-separated format (new format)
    IFS=',' read -ra TOKENS <<< "${LARK_ROOT_NODES}"
    for token in "${TOKENS[@]}"; do
      # Trim whitespace
      token=$(echo "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$token" ]; then
        ROOT_NODES+=("$token")
      fi
    done
  fi
fi

# Validate required variables
if [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ]; then
  echo "ERROR: LARK_APP_ID or LARK_APP_SECRET not found"
  echo "Please set them in .env file or as environment variables (GitHub Secrets)"
  exit 1
fi

if [ -z "$SPACE_ID" ]; then
  echo "ERROR: LARK_SPACE_ID not found"
  echo "Please set it in .env file or as environment variable (GitHub Secret)"
  exit 1
fi

if [ ${#ROOT_NODES[@]} -eq 0 ]; then
  echo "ERROR: LARK_ROOT_NODES not found or empty"
  echo "Please set it as GitHub Secret (comma-separated format: TOKEN1,TOKEN2,TOKEN3)"
  echo "For local testing, you can add it to .env file"
  exit 1
fi

# Load non-sensitive configuration from config.json
if [ -f config.json ]; then
  CONFIG_DATA=$(cat config.json)
  
  # Parse output configuration
  OUTPUT_DIRECTORY=$(echo "$CONFIG_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('output', {}).get('output_dir', 'output'))
except:
    print('output')
")
  
  JSON_FILE="$OUTPUT_DIRECTORY/$(echo "$CONFIG_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('output', {}).get('json_file', 'documents.json'))
except:
    print('documents.json')
")"
  
  # Parse options
  VERBOSE=$(echo "$CONFIG_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(str(data.get('options', {}).get('verbose', False)).lower())
except:
    print('false')
")
  
  INCLUDE_CONTENT=$(echo "$CONFIG_DATA" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(str(data.get('options', {}).get('include_content', True)).lower())
except:
    print('true')
")
else
  echo "ERROR: config.json file not found"
  exit 1
fi

# API Endpoints
AUTH_URL="https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
WIKI_BASE_URL="https://open.feishu.cn/open-apis/wiki/v2/spaces"
DOCX_API_URL="https://open.feishu.cn/open-apis/docx/v1/documents"
DRIVE_API_URL="https://open.feishu.cn/open-apis/drive/v1/files"

################################################################################
# GLOBAL VARIABLES
################################################################################

TENANT_TOKEN=""
declare -a ALL_DOCUMENTS=()  # Array to store all document info
DOC_COUNT=0

################################################################################
# HELPER FUNCTIONS
################################################################################

log() {
  if [ "$VERBOSE" = true ] || [ "$1" != "DEBUG" ]; then
    echo "$2"
  fi
}

log_error() {
  echo "ERROR: $1" >&2
}

get_tenant_token() {
  log "INFO" "Getting tenant access token..."
  
  local response=$(curl -s -X POST "$AUTH_URL" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"$APP_ID\",\"app_secret\":\"$APP_SECRET\"}")
  
  TENANT_TOKEN=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('code') == 0:
        print(data.get('tenant_access_token', ''))
    else:
        print('', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
  
  if [ -z "$TENANT_TOKEN" ]; then
    log_error "Failed to get tenant token"
    exit 1
  fi
  
  log "INFO" "✓ Tenant token obtained"
}

get_node_details() {
  local node_token=$1
  local response=$(curl -s -X GET "$WIKI_BASE_URL/$SPACE_ID/nodes/$node_token" \
    -H "Authorization: Bearer $TENANT_TOKEN")
  
  local result=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('code') == 0:
        node = data.get('data', {}).get('node', {})
        print(f\"{node.get('obj_token', '')}|{node.get('title', 'Unknown')}|{node.get('has_child', False)}\")
    else:
        error_msg = data.get('msg', 'Unknown error')
        error_code = data.get('code', '')
        print(f\"ERROR|{error_code}: {error_msg}\", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f\"ERROR|JSON parse error: {e}\", file=sys.stderr)
    sys.exit(1)
" 2>&1)
  
  if [[ "$result" =~ ^ERROR ]]; then
    log_error "API error for node $node_token: $result"
    return 1
  fi
  
  echo "$result"
}

get_children() {
  local parent_token=$1
  local response=$(curl -s -X GET "$WIKI_BASE_URL/$SPACE_ID/nodes?parent_node_token=$parent_token&page_size=50" \
    -H "Authorization: Bearer $TENANT_TOKEN")
  
  echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('code') == 0:
        items = data.get('data', {}).get('items', [])
        for item in items:
            title = item.get('title', 'Unknown').strip()
            token = item.get('node_token', '')
            has_child = item.get('has_child', False)
            print(f\"{token}|{title}|{has_child}\")
except:
    pass
" 2>/dev/null
}

################################################################################
# RECURSIVE TRAVERSAL FUNCTION
################################################################################

traverse_node() {
  local node_token=$1
  local title=$2
  local level=$3
  local parent_title=$4
  local indent_prefix=$5
  local parent_path=$6  # Directory path for this node
  
  log "DEBUG" "Traversing: $title (level $level)"
  
  # Get node details
  local node_details=$(get_node_details "$node_token")
  if [ -z "$node_details" ] || [[ "$node_details" =~ ^ERROR ]]; then
    log_error "Failed to get details for node: $node_token"
    if [ -n "$node_details" ]; then
      log_error "  Details: $node_details"
    fi
    return
  fi
  
  IFS='|' read -r doc_token node_title has_child <<< "$node_details"
  
  # Create safe directory name (remove special chars, spaces)
  local safe_title=$(echo "$node_title" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
  local current_path="${parent_path}/${safe_title}"
  
  # Store document info with path
  DOC_COUNT=$((DOC_COUNT + 1))
  ALL_DOCUMENTS+=("$DOC_COUNT|$level|$node_token|$doc_token|$node_title|$parent_title|$current_path")
  
  log "INFO" "${indent_prefix}📄 [$level] $node_title"
  log "DEBUG" "${indent_prefix}   Node Token: $node_token"
  log "DEBUG" "${indent_prefix}   Doc Token: $doc_token"
  log "DEBUG" "${indent_prefix}   Path: $current_path"
  
  # Get children if exists
  if [ "$has_child" = "true" ] || [ "$has_child" = "True" ]; then
    log "DEBUG" "${indent_prefix}   Has children: Yes"
    
    local children=$(get_children "$node_token")
    if [ -n "$children" ]; then
      local child_count=0
      # Use process substitution instead of pipe to avoid subshell
      while IFS='|' read -r child_token child_title child_has_child; do
        if [ -z "$child_token" ]; then
          continue
        fi
        
        child_count=$((child_count + 1))
        local next_level="$level.$child_count"
        local next_indent="${indent_prefix}│  "
        
        traverse_node "$child_token" "$child_title" "$next_level" "$node_title" "$next_indent" "$current_path"
      done < <(echo "$children")
    fi
  else
    log "DEBUG" "${indent_prefix}   Has children: No"
  fi
}

################################################################################
# CONTENT RETRIEVAL FUNCTIONS
################################################################################

get_document_blocks() {
  local doc_token=$1
  
  if [ -z "$TENANT_TOKEN" ]; then
    log_error "Tenant token not available"
    return 1
  fi
  
  local response=$(curl -s --max-time 30 -X GET "$DOCX_API_URL/$doc_token/blocks" \
    -H "Authorization: Bearer $TENANT_TOKEN" \
    -H "Content-Type: application/json")
  
  echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('code') == 0:
        blocks = data.get('data', {}).get('items', [])
        print(json.dumps(blocks))
    else:
        error_msg = data.get('msg', 'Unknown error')
        print(f'Error: {error_msg}', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f'Error parsing response: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

download_image() {
  local image_token=$1
  local output_path=$2
  
  if [ -z "$TENANT_TOKEN" ]; then
    log_error "Tenant token not available"
    return 1
  fi
  
  if [ -f "$output_path" ]; then
    return 0
  fi
  
  local response=$(curl -s --max-time 30 -X GET "https://open.feishu.cn/open-apis/drive/v1/medias/$image_token/download" \
    -H "Authorization: Bearer $TENANT_TOKEN" \
    -o "$output_path" 2>&1)
  
  if [ -f "$output_path" ] && [ -s "$output_path" ]; then
    local file_type=$(file -b --mime-type "$output_path" 2>/dev/null || echo "")
    if [[ "$file_type" == "application/json" ]] || [[ "$file_type" == "text/json" ]]; then
      local error_msg=$(cat "$output_path" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('msg', ''))" 2>/dev/null || echo "")
      if [[ "$error_msg" == *"docs:document.media:download"* ]] || [[ "$error_msg" == *"permission"* ]]; then
        rm -f "$output_path" 2>/dev/null
        log_error "Image download failed: Missing permission 'docs:document.media:download'. Please add this permission in Lark Developer Console."
        return 1
      fi
      rm -f "$output_path" 2>/dev/null
      return 1
    fi
    return 0
  else
    rm -f "$output_path" 2>/dev/null
    return 1
  fi
}

get_document_content() {
  local doc_token=$1
  
  local blocks_json=$(get_document_blocks "$doc_token")
  if [ -z "$blocks_json" ] || [ "$blocks_json" = "[]" ]; then
    return 1
  fi
  
  echo "$blocks_json" | python3 << 'PYEOF'
import sys
import json
import urllib.parse

def extract_text_from_elements(elements):
    if not elements:
        return ''
    parts = []
    for elem in elements:
        if 'text_run' in elem:
            content = elem['text_run'].get('content', '')
            style = elem.get('text_element_style', {})
            if 'link' in style:
                url = style['link'].get('url', '')
                url = urllib.parse.unquote(url)
                formatted_content = content
                if style.get('bold'):
                    formatted_content = f"**{formatted_content}**"
                if style.get('italic'):
                    formatted_content = f"*{formatted_content}*"
                parts.append(f"[{formatted_content}]({url})")
            else:
                if style.get('bold'):
                    content = f"**{content}**"
                if style.get('italic'):
                    content = f"*{content}*"
                if style.get('strikethrough'):
                    content = f"~~{content}~~"
                if style.get('inline_code'):
                    content = f"`{content}`"
                parts.append(content)
        elif 'mention_user' in elem:
            user_id = elem['mention_user'].get('user_id', '')
            parts.append(f"@User({user_id})")
        elif 'mention_doc' in elem:
            doc_token = elem['mention_doc'].get('token', '')
            parts.append(f"[Document]({doc_token})")
        elif 'equation' in elem:
            equation = elem['equation'].get('equation', '')
            parts.append(f"${equation}$")
    return ''.join(parts)

def blocks_to_markdown(blocks, images_dir='images'):
    markdown_lines = []
    block_map = {}
    for item in blocks:
        block_id = item.get('block_id', '')
        if block_id:
            block_map[block_id] = item
    
    processed = set()
    
    def process_block(block_id):
        if block_id in processed or block_id not in block_map:
            return
        processed.add(block_id)
        item = block_map[block_id]
        block_type = item.get('block_type')
        
        if block_type == 1:
            if 'page' in item:
                text = extract_text_from_elements(item['page'].get('elements', []))
                if text:
                    markdown_lines.append(f"# {text}")
        elif block_type == 2:
            if 'text' in item:
                text = extract_text_from_elements(item['text'].get('elements', []))
                if text:
                    markdown_lines.append(text)
        elif block_type == 3:
            if 'heading1' in item:
                text = extract_text_from_elements(item['heading1'].get('elements', []))
                if text:
                    markdown_lines.append(f"# {text}")
        elif block_type == 4:
            if 'heading2' in item:
                text = extract_text_from_elements(item['heading2'].get('elements', []))
                if text:
                    markdown_lines.append(f"## {text}")
        elif block_type == 5:
            if 'heading3' in item:
                text = extract_text_from_elements(item['heading3'].get('elements', []))
                if text:
                    markdown_lines.append(f"### {text}")
        elif block_type == 6:
            if 'heading4' in item:
                text = extract_text_from_elements(item['heading4'].get('elements', []))
                if text:
                    markdown_lines.append(f"#### {text}")
        elif block_type == 7:
            if 'heading5' in item:
                text = extract_text_from_elements(item['heading5'].get('elements', []))
                if text:
                    markdown_lines.append(f"##### {text}")
        elif block_type == 8:
            if 'heading6' in item:
                text = extract_text_from_elements(item['heading6'].get('elements', []))
                if text:
                    markdown_lines.append(f"###### {text}")
        elif block_type == 11:
            if 'bullet' in item:
                text = extract_text_from_elements(item['bullet'].get('elements', []))
                if text:
                    markdown_lines.append(f"- {text}")
        elif block_type == 12:
            if 'ordered' in item:
                text = extract_text_from_elements(item['ordered'].get('elements', []))
                if text:
                    markdown_lines.append(f"1. {text}")
        elif block_type == 27:
            if 'image' in item:
                image_token = item['image'].get('token', '')
                if image_token:
                    markdown_lines.append(f"![Image](images/{image_token}.png)")
        elif block_type == 34:
            if 'quote_container' in item:
                children = item.get('children', [])
                if children:
                    child_start_idx = len(markdown_lines)
                    for child_id in children:
                        process_block(child_id)
                    for i in range(child_start_idx, len(markdown_lines)):
                        if markdown_lines[i] and not markdown_lines[i].startswith('>'):
                            markdown_lines[i] = f"> {markdown_lines[i]}"
                else:
                    markdown_lines.append("> ")
                return
            elif 'quote' in item:
                text = extract_text_from_elements(item['quote'].get('elements', []))
                if text:
                    markdown_lines.append(f"> {text}")
        elif block_type == 15:
            if 'code' in item:
                language = item['code'].get('language', '')
                text = extract_text_from_elements(item['code'].get('elements', []))
                if text:
                    markdown_lines.append(f"```{language}")
                    markdown_lines.append(text)
                    markdown_lines.append("```")
        elif block_type == 13:
            if 'checklist' in item:
                checked = item['checklist'].get('checked', False)
                text = extract_text_from_elements(item['checklist'].get('elements', []))
                if text:
                    checkbox = "- [x]" if checked else "- [ ]"
                    markdown_lines.append(f"{checkbox} {text}")
        elif block_type == 19:
            if 'callout' in item:
                emoji = item['callout'].get('emoji_id', '')
                emoji_prefix = f"{emoji} " if emoji else ""
                children = item.get('children', [])
                if children:
                    child_start_idx = len(markdown_lines)
                    for child_id in children:
                        process_block(child_id)
                    for i in range(child_start_idx, len(markdown_lines)):
                        if markdown_lines[i] and not markdown_lines[i].startswith('>'):
                            markdown_lines[i] = f"> {emoji_prefix}{markdown_lines[i]}"
                else:
                    markdown_lines.append(f"> {emoji_prefix}*Callout*")
                return
        
        children = item.get('children', [])
        for child_id in children:
            process_block(child_id)
    
    root_blocks = [item for item in blocks if not item.get('parent_id')]
    
    if not root_blocks:
        for item in blocks:
            block_id = item.get('block_id', '')
            if block_id and block_id not in processed:
                process_block(block_id)
    else:
        for root_block in root_blocks:
            root_id = root_block.get('block_id', '')
            if root_id:
                process_block(root_id)
    
    return '\n\n'.join(markdown_lines) if markdown_lines else ''

try:
    input_data = sys.stdin.read()
    if not input_data or input_data.strip() == '':
        print('')
        sys.exit(0)
    blocks = json.loads(input_data)
    if not blocks:
        print('')
        sys.exit(0)
    markdown = blocks_to_markdown(blocks, 'images')
    print(markdown)
except json.JSONDecodeError as e:
    print(f'Error parsing JSON: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error converting blocks: {e}', file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
}

################################################################################
# OUTPUT FUNCTIONS
################################################################################

create_output_directory() {
  log "INFO" "Clearing existing output files..."
  
  # Remove output directory if exists
  if [ -d "$OUTPUT_DIRECTORY" ]; then
    rm -rf "$OUTPUT_DIRECTORY"
  fi
  
  # Create fresh directory structure
  mkdir -p "$OUTPUT_DIRECTORY"
  log "INFO" "Output directory ready: $OUTPUT_DIRECTORY"
}

generate_files_list() {
  log "INFO" "Generating AI tool discovery files..."
  
  local base_url="https://stelixx-studio.github.io/wiki"
  
  # Collect all markdown files with their titles
  local md_files=()
  local md_titles=()
  
  # Extract titles from markdown files directly
  while IFS= read -r file; do
    md_files+=("$file")
    # Extract title from markdown file (first # heading)
    local title=$(head -20 "$OUTPUT_DIRECTORY/$file" 2>/dev/null | grep -m 1 "^# " | sed 's/^# //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # Fallback to filename if title not found
    if [ -z "$title" ]; then
      title=$(echo "$file" | sed 's|.*/||' | sed 's|\.md$||' | sed 's|_| |g' | sed 's/^./\U&/' | sed 's/ \(.\)/ \U\1/g')
    fi
    md_titles+=("$title")
  done < <(find "$OUTPUT_DIRECTORY" -name "*.md" -type f | sed "s|^$OUTPUT_DIRECTORY/||" | sort)
  
  # Create llms.txt following the standard format (based on llmstxt.org specification)
  {
    echo "# Stelixx Wiki Documentation"
    echo ""
    echo "> Documentation site containing wiki content exported from Lark Wiki. All content is available as Markdown files, JSON metadata, and images."
    echo ""
    echo "## Documentation Files"
    echo ""
    local i=0
    for file in "${md_files[@]}"; do
      local title="${md_titles[$i]}"
      echo "- [$title]($base_url/$file): Documentation page"
      i=$((i + 1))
    done
    echo ""
    echo "## Resources"
    echo ""
    echo "- [Images Directory]($base_url/images/): All images referenced in the documentation"
    echo ""
    echo "## Access Information"
    echo ""
    echo "All files are publicly accessible via direct URLs. Markdown files contain the full documentation content."
  } > "$OUTPUT_DIRECTORY/llms.txt"
  
  # Create sitemap.xml for better AI tool discovery
  {
    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    echo "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"
    for file in "${md_files[@]}"; do
      echo "  <url>"
      echo "    <loc>$base_url/$file</loc>"
      echo "  </url>"
    done
    echo "</urlset>"
  } > "$OUTPUT_DIRECTORY/sitemap.xml"
  
  # Create index.html that redirects to llms.txt
  # This satisfies Perplexity's requirement for index.html while redirecting to llms.txt
  {
    echo "<!DOCTYPE html>"
    echo "<html>"
    echo "<head>"
    echo "<meta charset=\"UTF-8\">"
    echo "<meta http-equiv=\"refresh\" content=\"0; url=llms.txt\">"
    echo "<meta name=\"robots\" content=\"index, follow\">"
    echo "<title>Stelixx Wiki Documentation</title>"
    echo "</head>"
    echo "<body>"
    echo "<p>Redirecting to <a href=\"llms.txt\">llms.txt</a>...</p>"
    echo "</body>"
    echo "</html>"
  } > "$OUTPUT_DIRECTORY/index.html"
  
  log "INFO" "✓ LLMs index saved: llms.txt"
  log "INFO" "✓ Sitemap saved: sitemap.xml"
  log "INFO" "✓ Index page saved: index.html"
}

generate_structure_files() {
  log "INFO" "Generating directory structure files..."
  
  # Create images directory
  local images_dir="$OUTPUT_DIRECTORY/images"
  mkdir -p "$images_dir"
  
  # Create files in directory structure with actual content
  local doc_count=0
  for doc_info in "${ALL_DOCUMENTS[@]}"; do
    doc_count=$((doc_count + 1))
    IFS='|' read -r doc_num level node_token doc_token title parent doc_path <<< "$doc_info"
    
    log "INFO" "Processing document $doc_count/${#ALL_DOCUMENTS[@]}: $title"
    
    # Create safe file name (remove special chars, spaces)
    local safe_title=$(echo "$title" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
    
    # Determine file path
    # Root nodes have path like "/Welcome_to_Wiki" (starts with /, single level)
    # Nested nodes have path like "/Administrator_Manual/Create_workspace" (multiple levels)
    if [ -n "$doc_path" ] && [ "$doc_path" != "/" ]; then
      # Remove leading slash if present
      local clean_path="${doc_path#/}"
      # Count slashes to determine if it's root or nested
      local slash_count=$(echo "$clean_path" | tr -cd '/' | wc -c)
      if [ "$slash_count" -eq 0 ]; then
        # Root node: create file at root level
        local file_path="$OUTPUT_DIRECTORY/${clean_path}.md"
      else
        # Nested node: place file in directory structure
        local file_path="$OUTPUT_DIRECTORY/${clean_path}.md"
      fi
    else
      # Fallback: use safe_title
      local file_path="$OUTPUT_DIRECTORY/${safe_title}.md"
    fi
    
    # Ensure directory exists
    mkdir -p "$(dirname "$file_path")"
    
    # Get blocks and extract images
    local blocks_json=""
    local content=""
    
      if [ "$INCLUDE_CONTENT" = true ]; then
      blocks_json=$(get_document_blocks "$doc_token")
      
      if [ -n "$blocks_json" ] && [ "$blocks_json" != "[]" ] && [[ ! "$blocks_json" =~ ^Error ]]; then
        # Extract and download images
        echo "$blocks_json" | timeout 10 python3 -c "
import sys, json
try:
    blocks = json.load(sys.stdin)
    for block in blocks:
        if block.get('block_type') == 27 and 'image' in block:
            image_token = block['image'].get('token', '')
            if image_token:
                print(image_token)
except:
    pass
" 2>/dev/null | while read -r image_token; do
          if [ -n "$image_token" ]; then
            local image_path="$images_dir/${image_token}.png"
            if [ ! -f "$image_path" ]; then
              if download_image "$image_token" "$image_path"; then
                log "INFO" "  Downloaded image: ${image_token}.png"
              else
                log_error "  Failed to download image: ${image_token}.png"
              fi
            fi
          fi
        done
        
        # Convert blocks to markdown with timeout
        local temp_blocks_file=$(mktemp)
        printf '%s' "$blocks_json" > "$temp_blocks_file"
        content=$(timeout 30 python3 - "$temp_blocks_file" << 'PYEOF'
import sys
import json
import urllib.parse

def extract_text_from_elements(elements):
    if not elements:
        return ''
    parts = []
    for elem in elements:
        if 'text_run' in elem:
            content = elem['text_run'].get('content', '')
            style = elem.get('text_element_style', {})
            if 'link' in style:
                url = style['link'].get('url', '')
                url = urllib.parse.unquote(url)
                formatted_content = content
                if style.get('bold'):
                    formatted_content = f"**{formatted_content}**"
                if style.get('italic'):
                    formatted_content = f"*{formatted_content}*"
                parts.append(f"[{formatted_content}]({url})")
            else:
                if style.get('bold'):
                    content = f"**{content}**"
                if style.get('italic'):
                    content = f"*{content}*"
                if style.get('strikethrough'):
                    content = f"~~{content}~~"
                if style.get('inline_code'):
                    content = f"`{content}`"
                parts.append(content)
        elif 'mention_user' in elem:
            user_id = elem['mention_user'].get('user_id', '')
            parts.append(f"@User({user_id})")
        elif 'mention_doc' in elem:
            doc_token = elem['mention_doc'].get('token', '')
            parts.append(f"[Document]({doc_token})")
        elif 'equation' in elem:
            equation = elem['equation'].get('equation', '')
            parts.append(f"${equation}$")
    return ''.join(parts)

def blocks_to_markdown(blocks, images_dir='images'):
    markdown_lines = []
    block_map = {}
    for item in blocks:
        block_id = item.get('block_id', '')
        if block_id:
            block_map[block_id] = item
    
    processed = set()
    
    def process_block(block_id):
        if block_id in processed or block_id not in block_map:
            return
        processed.add(block_id)
        item = block_map[block_id]
        block_type = item.get('block_type')
        
        if block_type == 1:
            if 'page' in item:
                text = extract_text_from_elements(item['page'].get('elements', []))
                if text:
                    markdown_lines.append(f"# {text}")
        elif block_type == 2:
            if 'text' in item:
                text = extract_text_from_elements(item['text'].get('elements', []))
                if text:
                    markdown_lines.append(text)
        elif block_type == 3:
            if 'heading1' in item:
                text = extract_text_from_elements(item['heading1'].get('elements', []))
                if text:
                    markdown_lines.append(f"# {text}")
        elif block_type == 4:
            if 'heading2' in item:
                text = extract_text_from_elements(item['heading2'].get('elements', []))
                if text:
                    markdown_lines.append(f"## {text}")
        elif block_type == 5:
            if 'heading3' in item:
                text = extract_text_from_elements(item['heading3'].get('elements', []))
                if text:
                    markdown_lines.append(f"### {text}")
        elif block_type == 6:
            if 'heading4' in item:
                text = extract_text_from_elements(item['heading4'].get('elements', []))
                if text:
                    markdown_lines.append(f"#### {text}")
        elif block_type == 7:
            if 'heading5' in item:
                text = extract_text_from_elements(item['heading5'].get('elements', []))
                if text:
                    markdown_lines.append(f"##### {text}")
        elif block_type == 8:
            if 'heading6' in item:
                text = extract_text_from_elements(item['heading6'].get('elements', []))
                if text:
                    markdown_lines.append(f"###### {text}")
        elif block_type == 11:
            if 'bullet' in item:
                text = extract_text_from_elements(item['bullet'].get('elements', []))
                if text:
                    markdown_lines.append(f"- {text}")
        elif block_type == 12:
            if 'ordered' in item:
                text = extract_text_from_elements(item['ordered'].get('elements', []))
                if text:
                    markdown_lines.append(f"1. {text}")
        elif block_type == 27:
            if 'image' in item:
                image_token = item['image'].get('token', '')
                if image_token:
                    markdown_lines.append(f"![Image](images/{image_token}.png)")
        elif block_type == 34:
            if 'quote_container' in item:
                children = item.get('children', [])
                if children:
                    child_start_idx = len(markdown_lines)
                    for child_id in children:
                        process_block(child_id)
                    for i in range(child_start_idx, len(markdown_lines)):
                        if markdown_lines[i] and not markdown_lines[i].startswith('>'):
                            markdown_lines[i] = f"> {markdown_lines[i]}"
                else:
                    markdown_lines.append("> ")
                return
            elif 'quote' in item:
                text = extract_text_from_elements(item['quote'].get('elements', []))
                if text:
                    markdown_lines.append(f"> {text}")
        elif block_type == 15:
            if 'code' in item:
                language = item['code'].get('language', '')
                text = extract_text_from_elements(item['code'].get('elements', []))
                if text:
                    markdown_lines.append(f"```{language}")
                    markdown_lines.append(text)
                    markdown_lines.append("```")
        elif block_type == 13:
            if 'checklist' in item:
                checked = item['checklist'].get('checked', False)
                text = extract_text_from_elements(item['checklist'].get('elements', []))
                if text:
                    checkbox = "- [x]" if checked else "- [ ]"
                    markdown_lines.append(f"{checkbox} {text}")
        elif block_type == 19:
            if 'callout' in item:
                emoji = item['callout'].get('emoji_id', '')
                emoji_prefix = f"{emoji} " if emoji else ""
                children = item.get('children', [])
                if children:
                    child_start_idx = len(markdown_lines)
                    for child_id in children:
                        process_block(child_id)
                    for i in range(child_start_idx, len(markdown_lines)):
                        if markdown_lines[i] and not markdown_lines[i].startswith('>'):
                            markdown_lines[i] = f"> {emoji_prefix}{markdown_lines[i]}"
                else:
                    markdown_lines.append(f"> {emoji_prefix}*Callout*")
                return
        
        children = item.get('children', [])
        for child_id in children:
            process_block(child_id)
    
    root_blocks = [item for item in blocks if not item.get('parent_id')]
    
    if not root_blocks:
        for item in blocks:
            block_id = item.get('block_id', '')
            if block_id and block_id not in processed:
                process_block(block_id)
    else:
        for root_block in root_blocks:
            root_id = root_block.get('block_id', '')
            if root_id:
                process_block(root_id)
    
    return '\n\n'.join(markdown_lines) if markdown_lines else ''

try:
    blocks_file = sys.argv[1]
    with open(blocks_file, 'r', encoding='utf-8') as f:
        input_data = f.read()
    if not input_data or input_data.strip() == '':
        print('')
        sys.exit(0)
    blocks = json.loads(input_data)
    if not blocks:
        print('')
        sys.exit(0)
    markdown = blocks_to_markdown(blocks, 'images')
    print(markdown)
except json.JSONDecodeError as e:
    print(f'Error parsing JSON: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error converting blocks: {e}', file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
        2>&1)
        rm -f "$temp_blocks_file"
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          log_error "Content conversion failed for document: $title (exit code: $exit_code)"
          content="*Content conversion failed*"
        elif [ -z "$content" ]; then
          log_error "Content conversion returned empty for document: $title"
          content="*Content conversion failed*"
        elif [[ "$content" =~ ^Error ]]; then
          log_error "Content conversion error for document: $title: $content"
          content="*Content conversion failed*"
        elif [[ "$content" =~ ^timeout ]]; then
          log_error "Content conversion timeout for document: $title"
          content="*Content conversion failed*"
        fi
      else
        content="*Content not available*"
      fi
    else
      content="*Content retrieval disabled (set INCLUDE_CONTENT=true in config.json)*"
    fi
    
    # Create markdown file with metadata
    {
      echo "# $title"
      echo ""
      echo "**Level:** $level"
      echo "**Node Token:** \`$node_token\`"
      echo "**Document Token:** \`$doc_token\`"
      if [ -n "$parent" ] && [ "$parent" != "ROOT" ]; then
        echo "**Parent:** $parent"
      fi
      echo "**URL:** https://qjpju0vjxley.jp.larksuite.com/wiki/$node_token"
      echo ""
      echo "---"
      echo ""
          echo "$content"
    } > "$file_path"
  done
  
  log "INFO" "✓ Directory structure created: $OUTPUT_DIRECTORY/"
  log "INFO" "  Created $(find "$OUTPUT_DIRECTORY" -type f -name '*.md' | wc -l | tr -d ' ') markdown files"
  log "INFO" "  Created $(find "$images_dir" -type f 2>/dev/null | wc -l | tr -d ' ') image files"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
  echo "=================================================================================="
  echo "         Lark Wiki Document Retrieval Script"
  echo "=================================================================================="
  echo ""
  echo "Configuration:"
  echo "  Space ID: $SPACE_ID"
  echo "  Root Nodes: ${#ROOT_NODES[@]}"
  echo "  Include Content: $INCLUDE_CONTENT"
  echo "  Verbose: $VERBOSE"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Setup
  create_output_directory
  get_tenant_token
  
  # Traverse all root nodes
  log "INFO" "Starting recursive traversal..."
  echo ""
  
  local root_index=0
  for root_token in "${ROOT_NODES[@]}"; do
    root_index=$((root_index + 1))
    # Get title from API (traverse_node will also get it, but we use it for logging)
    local node_details=$(get_node_details "$root_token")
    local root_title=""
    if [ -n "$node_details" ]; then
      IFS='|' read -r doc_token root_title has_child <<< "$node_details"
    fi
    log "INFO" "Processing root: ${root_title:-$root_token}"
    traverse_node "$root_token" "${root_title:-Unknown}" "$root_index" "ROOT" "" ""
    echo ""
  done
  
  log "INFO" "✓ Traversal complete! Found $DOC_COUNT documents"
  echo ""
  
  # Generate reports
  generate_json_report
  
  # Generate directory structure files
  generate_structure_files
  
  # Generate files list for easy access
  generate_files_list
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "✅ SUCCESS!"
  echo ""
  echo "📊 Results:"
  echo "   Total Documents: $DOC_COUNT"
  echo "   Root Documents: ${#ROOT_NODES[@]}"
  echo "   Nested Documents: $((DOC_COUNT - ${#ROOT_NODES[@]}))"
  echo ""
  echo "📂 Output Directory:"
  echo "   - $OUTPUT_DIRECTORY/"
  echo ""
  echo "=================================================================================="
}

# Run main function
main

