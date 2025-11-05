#!/usr/bin/env python3
"""
Lark Wiki Document Content Retrieval Script
Retrieves actual document content using MCP tools or Lark API

Usage:
    python3 get_wiki_content.py [--json-input wiki_documents.json]
"""

import json
import sys
import os
import subprocess
from pathlib import Path

# Configuration
MCP_SERVER = "Lark MCP"
INPUT_FILE = "temp/wiki_documents.json"
OUTPUT_FILE = "temp/wiki_documents_with_content.txt"

def get_content_via_mcp_tool(document_token):
    """
    Get document content using MCP tool.
    Note: This requires the MCP server to be running and accessible.
    For now, we'll show how to call it manually.
    """
    # MCP tool call format:
    # mcp_Lark_MCP_docx_v1_document_rawContent({"path": {"document_id": document_token}})
    
    # Since we can't call MCP tools directly from Python,
    # we'll need to use curl with user access token or
    # provide instructions for manual retrieval
    
    print(f"  → Would retrieve content for: {document_token}")
    return None

def get_content_via_api(document_token, user_token):
    """
    Get document content using Lark API with user access token.
    """
    api_url = f"https://open.feishu.cn/open-apis/docx/v1/documents/{document_token}/raw_content"
    
    response = subprocess.run(
        [
            "curl", "-s", "-X", "GET",
            api_url,
            "-H", f"Authorization: Bearer {user_token}"
        ],
        capture_output=True,
        text=True
    )
    
    if response.returncode == 0:
        try:
            data = json.loads(response.stdout)
            if data.get("code") == 0:
                return data.get("data", {}).get("content", "")
        except:
            pass
    
    return None

def main():
    """Main function to retrieve content for all documents."""
    
    # Load document metadata
    if not os.path.exists(INPUT_FILE):
        print(f"Error: Input file not found: {INPUT_FILE}")
        print("Please run get_all_wiki_docs.sh first to generate the JSON file.")
        sys.exit(1)
    
    with open(INPUT_FILE, 'r') as f:
        documents = json.load(f)
    
    print("=" * 80)
    print("Lark Wiki Document Content Retrieval")
    print("=" * 80)
    print(f"\nFound {len(documents)} documents")
    print(f"Input: {INPUT_FILE}")
    print(f"Output: {OUTPUT_FILE}")
    print("\n" + "-" * 80)
    
    # Check if user token is available
    user_token = os.environ.get("LARK_USER_ACCESS_TOKEN")
    
    if not user_token:
        print("\n⚠️  User Access Token not found!")
        print("\nTo retrieve content, you need:")
        print("  1. Set LARK_USER_ACCESS_TOKEN environment variable")
        print("     OR")
        print("  2. Use MCP tools manually (docx.v1.document.rawContent)")
        print("\n📋 Document Tokens to retrieve:")
        print("")
        for doc in documents:
            print(f"  • {doc['title']}: {doc['document_token']}")
        
        print("\n💡 To retrieve content using MCP tools:")
        print("   Call: mcp_Lark_MCP_docx_v1_document_rawContent")
        print("   With: document_id = {document_token}")
        print("\n💡 To retrieve via API:")
        print("   export LARK_USER_ACCESS_TOKEN='your_token'")
        print("   python3 get_wiki_content.py")
        
        sys.exit(0)
    
    # Retrieve content for each document
    results = []
    for i, doc in enumerate(documents, 1):
        print(f"\n[{i}/{len(documents)}] Retrieving: {doc['title']}")
        print(f"  Token: {doc['document_token']}")
        
        content = get_content_via_api(doc['document_token'], user_token)
        
        if content:
            doc['content'] = content
            print(f"  ✅ Content retrieved ({len(content)} characters)")
        else:
            doc['content'] = None
            print(f"  ❌ Failed to retrieve content")
        
        results.append(doc)
    
    # Save results
    output_path = Path(OUTPUT_FILE)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write("=" * 80 + "\n")
        f.write("LARK WIKI DOCUMENTS - WITH CONTENT\n")
        f.write("=" * 80 + "\n\n")
        
        for doc in results:
            f.write(f"📄 DOCUMENT {doc['number']}: {doc['title']}\n")
            f.write(f"   Level: {doc['level']}\n")
            f.write(f"   Node Token: {doc['node_token']}\n")
            f.write(f"   Document Token: {doc['document_token']}\n")
            f.write(f"   URL: {doc['url']}\n")
            f.write("\n" + "-" * 80 + "\n\n")
            
            if doc.get('content'):
                f.write(doc['content'])
                f.write("\n\n")
            else:
                f.write("[Content not available]\n\n")
            
            f.write("-" * 80 + "\n\n")
    
    print("\n" + "=" * 80)
    print(f"✅ Content retrieval complete!")
    print(f"📁 Output saved to: {OUTPUT_FILE}")
    print("=" * 80)

if __name__ == "__main__":
    main()

