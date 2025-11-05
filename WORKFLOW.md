# Lark Wiki Document Retrieval Workflow

## Quick Summary

This workflow retrieves all documents (including nested ones) from a Lark Wiki using a hybrid approach: **Direct API calls** for structure + **MCP tools** for content.

---

## 🔑 The Core Problem

**Challenge:** Wiki has hierarchical structure (root → children → grandchildren). Need to:
1. Discover all documents in the tree
2. Get document content for each

**Limitation:** 
- Tenant token can't list root nodes
- Need user token for content
- Must know root tokens to start traversal

---

## 📋 The Solution: 4-Phase Workflow

### **Phase 1: Discovery & Setup**

1. **Get Tenant Access Token**
   ```bash
   POST /open-apis/auth/v3/tenant_access_token/internal
   Body: { "app_id": "...", "app_secret": "..." }
   ```

2. **Identify Root Nodes**
   - Extract from wiki URLs: `https://...larksuite.com/wiki/{TOKEN}`
   - Or use MCP `wiki_v2_space_list`
   - Or manually collect from wiki interface

---

### **Phase 2: Recursive Tree Traversal**

**For each root node:**

```bash
# Step 1: Get children
GET /open-apis/wiki/v2/spaces/{space_id}/nodes?parent_node_token={root_token}

# Step 2: For each child, get details
GET /open-apis/wiki/v2/spaces/{space_id}/nodes/{node_token}

# Step 3: If child has children, recursively traverse
if (has_child == true) {
    traverse(child_token)
}
```

**Recursive Algorithm:**
```
function traverse(node_token):
  1. Get children of node_token
  2. For each child:
     - Get child details (extract obj_token = document token)
     - Store: {title, node_token, doc_token}
     - If has_child == true:
         traverse(child_token)  ← RECURSIVE CALL
```

---

### **Phase 3: Content Retrieval**

**For each document token collected:**

```bash
# Use MCP tool (has user access token)
mcp_Lark_MCP_docx_v1_document_rawContent({
  document_id: "{obj_token}"
})
```

**Why MCP?**
- Has user access token (via OAuth)
- Required for document content access
- Tenant token can't get content

---

### **Phase 4: Data Organization**

1. Structure documents hierarchically
2. Generate report with:
   - Document titles
   - Node tokens
   - Document tokens
   - URLs
   - Full content
   - Tree structure

---

## 🔄 Complete Flow Diagram

```
START
 │
 ├─► Get Tenant Token
 │
 ├─► Identify Root Nodes (manual/URLs)
 │
 ├─► FOR EACH ROOT:
 │   │
 │   ├─► Get Children List
 │   │   └─► API: GET /nodes?parent_node_token={root}
 │   │
 │   ├─► FOR EACH CHILD:
 │   │   │
 │   │   ├─► Get Node Details
 │   │   │   └─► Extract: obj_token (document token)
 │   │   │
 │   │   ├─► IF has_child == true:
 │   │   │   └─► RECURSIVELY traverse(child_token)
 │   │   │
 │   │   └─► Store metadata
 │   │
 │   └─► Continue to next root
 │
 ├─► FOR EACH DOCUMENT TOKEN:
 │   │
 │   ├─► Get Document Content
 │   │   └─► MCP: docx.v1.document.rawContent
 │   │
 │   └─► Store content
 │
 ├─► Organize Data Hierarchically
 ├─► Generate Report
 └─► END
```

---

## 💻 Example Implementation

### Bash Script (Simplified)

```bash
#!/bin/bash

# 1. Get tenant token
TOKEN=$(curl -s -X POST "..." | parse_token)

# 2. Root nodes
ROOTS=(
  "TGGowP5sEi3Pl5kJwwejtkOlpYd"  # Welcome to Wiki
  "Ni02wJudVi3d1HkvTyhj1A7up0c"  # Administrator Manual  
  "WAcTwEvu4i9Jyjk7ZOajXvAzpKh"  # Member Manual
)

# 3. Recursive function
get_nested_docs() {
  local parent=$1
  local level=$2
  
  # Get children
  CHILDREN=$(curl -s -X GET \
    "https://open.feishu.cn/open-apis/wiki/v2/spaces/$SPACE_ID/nodes?parent_node_token=$parent" \
    -H "Authorization: Bearer $TOKEN")
  
  # Process each child
  echo "$CHILDREN" | parse_children | while read token title has_child; do
    echo "[$level] $title"
    
    # Get document token
    DOC_TOKEN=$(get_node_details "$token" | extract_obj_token)
    
    # Recursive if has children
    if [ "$has_child" = "true" ]; then
      get_nested_docs "$token" "$level.1"
    fi
  done
}

# 4. Traverse all roots
for root in "${ROOTS[@]}"; do
  get_nested_docs "$root" "1"
done

# 5. Get content (via MCP tools)
for doc_token in "${DOC_TOKENS[@]}"; do
  content=$(mcp_docx_rawContent "$doc_token")
  save_content "$doc_token" "$content"
done
```

---

## 🎯 Key Insights

### Why Two Approaches?

| Task | Method | Token Type |
|------|--------|------------|
| Get children | Direct API | tenant_access_token |
| Get content | MCP tool | user_access_token |

**Reason:** Tenant token can traverse structure, but user token needed for content.

### Why Recursive?

- Wiki has unlimited nesting depth
- Need to traverse entire tree
- Recursive = elegant solution for tree structures

### Why Need Root Tokens?

- Can't list root nodes with tenant token (permission denied)
- Must start from known root tokens
- Get from URLs or manual collection

---

## ✅ Success Metrics

Workflow succeeds when:
- ✅ All root nodes identified
- ✅ All nested documents discovered
- ✅ All document tokens collected
- ✅ All content retrieved
- ✅ Hierarchical structure preserved

---

## 📊 Real Example Results

```
📄 [1] Welcome to Wiki
   └─ No children

📄 [2] Administrator Manual
   ├─ [2.1] Create workspace
   └─ [2.2] Manage members

📄 [3] Member Manual
   ├─ [3.1] Enter a workspace
   ├─ [3.2] Team collaboration
   ├─ [3.3] Add pages
   ├─ [3.4] Access permissions
   └─ [3.5] FAQs

Total: 9 documents retrieved ✅
```

---

## 🔍 Troubleshooting

| Problem | Solution |
|---------|----------|
| "permission denied" listing roots | Use tenant token only for children, get roots manually |
| Empty search results | Search API unreliable, use manual token collection |
| MCP tool not found | Check mcp.json config, ensure tool enabled |
| Missing nested docs | Verify recursive traversal, check has_child flags |

---

## 📝 Summary

**The workflow:**
1. Get tenant token → Traverse structure (children)
2. Get user token (MCP) → Retrieve content
3. Recursively traverse from known root nodes
4. Collect all document tokens
5. Retrieve content for all documents
6. Organize hierarchically

**Result:** Complete wiki tree with all nested documents and content! 🎉

