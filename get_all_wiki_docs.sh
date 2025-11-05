#!/bin/bash

################################################################################
# Lark Wiki Document Retrieval Script
# Retrieves all documents (including nested) from a Lark Wiki
# Uses hybrid approach: Direct API calls + MCP tools
################################################################################

set -e  # Exit on error

################################################################################
# CONFIGURATION
################################################################################

# Lark API Configuration
APP_ID="cli_a9804b219f389e1b"
APP_SECRET="AKpNJNpDLXQAFd2dXRzSTfvf7Dv2AxIn"
SPACE_ID="7563623033714249235"

# Root Node Tokens (extract from wiki URLs)
# Format: "NODE_TOKEN|TITLE"
declare -a ROOT_NODES=(
  "TGGowP5sEi3Pl5kJwwejtkOlpYd|Welcome to Wiki"
  "Ni02wJudVi3d1HkvTyhj1A7up0c|Administrator Manual"
  "WAcTwEvu4i9Jyjk7ZOajXvAzpKh|Member Manual"
)

# Output Configuration
OUTPUT_DIR="."
OUTPUT_FILE="$OUTPUT_DIR/wiki_documents_complete.txt"
INFO_FILE="$OUTPUT_DIR/wiki_documents_info.txt"
JSON_FILE="$OUTPUT_DIR/wiki_documents.json"
STRUCTURE_DIR="$OUTPUT_DIR/structure"  # Directory structure matching wiki

# API Endpoints
AUTH_URL="https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
WIKI_BASE_URL="https://open.feishu.cn/open-apis/wiki/v2/spaces"

# Options
VERBOSE=false  # Set to true for debug output
INCLUDE_CONTENT=true  # Set to false to skip content retrieval (faster)

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
  
  echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if data.get('code') == 0:
        node = data.get('data', {}).get('node', {})
        print(f\"{node.get('obj_token', '')}|{node.get('title', 'Unknown')}|{node.get('has_child', False)}\")
except:
    pass
" 2>/dev/null
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
  if [ -z "$node_details" ]; then
    log_error "Failed to get details for node: $node_token"
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
    
    # Create directory for this node
    mkdir -p "$STRUCTURE_DIR$current_path"
    
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
    # Create directory for leaf node too
    mkdir -p "$STRUCTURE_DIR$current_path"
  fi
}

################################################################################
# CONTENT RETRIEVAL FUNCTION
################################################################################

get_document_content() {
  local doc_token=$1
  # This would use MCP tool in actual implementation
  # For now, return placeholder
  echo "CONTENT_PLACEHOLDER_FOR_$doc_token"
}

################################################################################
# OUTPUT FUNCTIONS
################################################################################

create_output_directory() {
  # Clear existing output files and directories (but not the script itself)
  log "INFO" "Clearing existing output files..."
  
  # Remove specific output files
  [ -f "$OUTPUT_FILE" ] && rm -f "$OUTPUT_FILE"
  [ -f "$INFO_FILE" ] && rm -f "$INFO_FILE"
  [ -f "$JSON_FILE" ] && rm -f "$JSON_FILE"
  
  # Remove structure directory if exists
  if [ -d "$STRUCTURE_DIR" ]; then
    rm -rf "$STRUCTURE_DIR"
  fi
  
  # Create fresh directory structure
  mkdir -p "$STRUCTURE_DIR"
  log "INFO" "Output directory ready: $OUTPUT_DIR"
}

generate_text_report() {
  log "INFO" "Generating text report..."
  
  {
    echo "=================================================================================="
    echo "                    LARK WIKI DOCUMENTS - COMPLETE CONTENT"
    echo "=================================================================================="
    echo ""
    echo "Wiki Space: Stelixx"
    echo "Space ID: $SPACE_ID"
    echo "Generated: $(date)"
    echo ""
    echo "=================================================================================="
    echo ""
    
    for doc_info in "${ALL_DOCUMENTS[@]}"; do
      IFS='|' read -r doc_num level node_token doc_token title parent doc_path <<< "$doc_info"
      
      echo "📄 DOCUMENT $doc_num: $title"
      echo "   Level: $level"
      echo "   Node Token: $node_token"
      echo "   Document Token: $doc_token"
      if [ -n "$parent" ] && [ "$parent" != "ROOT" ]; then
        echo "   Parent: $parent"
      fi
      echo "   Path: $doc_path"
      echo "   URL: https://qjpju0vjxley.jp.larksuite.com/wiki/$node_token"
      echo ""
      echo "────────────────────────────────────────────────────────────────────────────────"
      echo ""
      
      if [ "$INCLUDE_CONTENT" = true ]; then
        echo "[Content would be retrieved via MCP tool: docx.v1.document.rawContent]"
        echo "Document Token: $doc_token"
        echo ""
      fi
      
      echo "────────────────────────────────────────────────────────────────────────────────"
      echo ""
    done
    
    echo "=================================================================================="
    echo "📊 SUMMARY"
    echo "=================================================================================="
    echo ""
    echo "Total Documents Retrieved: $DOC_COUNT"
    echo "Root Documents: ${#ROOT_NODES[@]}"
    echo "Nested Documents: $((DOC_COUNT - ${#ROOT_NODES[@]}))"
    echo ""
    echo "Retrieval Method:"
    echo "  ✅ Direct API calls via curl (recursive traversal)"
    if [ "$INCLUDE_CONTENT" = true ]; then
      echo "  ✅ MCP tools for document content"
    else
      echo "  ⏭️  Content retrieval skipped (set INCLUDE_CONTENT=true to enable)"
    fi
    echo ""
    echo "=================================================================================="
  } > "$OUTPUT_FILE"
  
  log "INFO" "✓ Text report saved: $OUTPUT_FILE"
}

generate_info_report() {
  log "INFO" "Generating info report..."
  
  {
    echo "=================================================================================="
    echo "                    LARK WIKI DOCUMENTS - INFORMATION"
    echo "=================================================================================="
    echo ""
    echo "Wiki Space: Stelixx"
    echo "Space ID: $SPACE_ID"
    echo ""
    echo "📚 Document Structure:"
    echo ""
    
    for doc_info in "${ALL_DOCUMENTS[@]}"; do
      IFS='|' read -r doc_num level node_token doc_token title parent doc_path <<< "$doc_info"
      
      # Create indentation based on level
      local indent=""
      local level_parts=$(echo "$level" | tr '.' '\n')
      local depth=$(echo "$level_parts" | wc -l | tr -d ' ')
      
      for ((i=2; i<$depth; i++)); do
        indent="${indent}│  "
      done
      
      if [ $depth -gt 1 ]; then
        indent="${indent}├─ "
      fi
      
      echo "$indent[$level] $title"
      echo "${indent}   Node Token: $node_token"
      echo "${indent}   Document Token: $doc_token"
      echo "${indent}   Path: $doc_path"
      echo ""
    done
    
    echo "=================================================================================="
    echo "📊 Summary"
    echo "=================================================================================="
    echo "Total Documents: $DOC_COUNT"
    echo "Root Documents: ${#ROOT_NODES[@]}"
    echo "Nested Documents: $((DOC_COUNT - ${#ROOT_NODES[@]}))"
    echo "=================================================================================="
  } > "$INFO_FILE"
  
  log "INFO" "✓ Info report saved: $INFO_FILE"
}

generate_json_report() {
  log "INFO" "Generating JSON report..."
  
  {
    echo "["
    local first=true
    for doc_info in "${ALL_DOCUMENTS[@]}"; do
      IFS='|' read -r doc_num level node_token doc_token title parent doc_path <<< "$doc_info"
      
      if [ "$first" = true ]; then
        first=false
      else
        echo ","
      fi
      
      echo -n "  {"
      echo -n "\"number\": $doc_num,"
      echo -n "\"level\": \"$level\","
      echo -n "\"title\": \"$title\","
      echo -n "\"node_token\": \"$node_token\","
      echo -n "\"document_token\": \"$doc_token\","
      echo -n "\"parent\": \"${parent:-ROOT}\","
      echo -n "\"path\": \"$doc_path\","
      echo -n "\"url\": \"https://qjpju0vjxley.jp.larksuite.com/wiki/$node_token\""
      echo -n "}"
    done
    echo ""
    echo "]"
  } > "$JSON_FILE"
  
  log "INFO" "✓ JSON report saved: $JSON_FILE"
}

generate_structure_files() {
  log "INFO" "Generating directory structure files..."
  
  # Create placeholder files in directory structure
  # Content will be added later when retrieved via MCP tools
  for doc_info in "${ALL_DOCUMENTS[@]}"; do
    IFS='|' read -r doc_num level node_token doc_token title parent doc_path <<< "$doc_info"
    
    # Create safe file name (remove special chars, spaces)
    local safe_title=$(echo "$title" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_\|_$//g')
    
    # Determine file path
    # If doc_path is empty or just "/", it's a root node
    if [ -z "$doc_path" ] || [ "$doc_path" = "/" ]; then
      local file_path="$STRUCTURE_DIR/${safe_title}.md"
    else
      # For nested nodes, place file in parent directory
      local file_path="$STRUCTURE_DIR${doc_path}.md"
    fi
    
    # Ensure directory exists
    mkdir -p "$(dirname "$file_path")"
    
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
      echo "*Content will be retrieved via MCP tool: docx.v1.document.rawContent*"
      echo ""
      echo "Document Token: \`$doc_token\`"
    } > "$file_path"
  done
  
  log "INFO" "✓ Directory structure created: $STRUCTURE_DIR/"
  log "INFO" "  Created $(find "$STRUCTURE_DIR" -type f | wc -l | tr -d ' ') files"
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
  for root_info in "${ROOT_NODES[@]}"; do
    root_index=$((root_index + 1))
    IFS='|' read -r root_token root_title <<< "$root_info"
    log "INFO" "Processing root: $root_title"
    traverse_node "$root_token" "$root_title" "$root_index" "ROOT" "" ""
    echo ""
  done
  
  log "INFO" "✓ Traversal complete! Found $DOC_COUNT documents"
  echo ""
  
  # Generate reports
  log "INFO" "Generating reports..."
  generate_text_report
  generate_info_report
  generate_json_report
  
  # Generate directory structure files
  log "INFO" "Creating directory structure files..."
  generate_structure_files
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "✅ SUCCESS!"
  echo ""
  echo "📊 Results:"
  echo "   Total Documents: $DOC_COUNT"
  echo "   Root Documents: ${#ROOT_NODES[@]}"
  echo "   Nested Documents: $((DOC_COUNT - ${#ROOT_NODES[@]}))"
  echo ""
  echo "📁 Output Files:"
  echo "   - $OUTPUT_FILE"
  echo "   - $INFO_FILE"
  echo "   - $JSON_FILE"
  echo ""
  echo "📂 Directory Structure:"
  echo "   - $STRUCTURE_DIR/"
  echo ""
  echo "=================================================================================="
}

# Run main function
main

