#!/bin/bash

# Script to extract individual pages from Confluence XML export and convert to Markdown
# with proper Wiki.js directory structure
# Usage: ./extract_confluence_pages_with_paths.sh <entities.xml> [output_directory] [--skip-attachments]

# Check if input file is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 <entities.xml> [output_directory] [--skip-attachments]"
    echo "Example: $0 entities.xml output_pages"
    echo "Options:"
    echo "  --skip-attachments    Skip copying attachment files (faster processing)"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_DIR="${2:-confluence_pages}"
SKIP_ATTACHMENTS=false

# Check for --skip-attachments flag in any position
for arg in "$@"; do
    if [ "$arg" = "--skip-attachments" ]; then
        SKIP_ATTACHMENTS=true
        echo "Note: Skipping attachment file copying"
    fi
done

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found!"
    exit 1
fi

# Get the directory containing the XML file (where attachments folder should be)
XML_DIR=$(dirname "$INPUT_FILE")
ATTACHMENTS_DIR="$XML_DIR/attachments"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "Processing Confluence XML export..."
echo "Input file: $INPUT_FILE"
echo "Output directory: $OUTPUT_DIR"
echo "Attachments directory: $ATTACHMENTS_DIR"

# Create a temporary working directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Python script to extract pages
python3 - "$INPUT_FILE" "$TEMP_DIR" "$ATTACHMENTS_DIR" "$OUTPUT_DIR" "$SKIP_ATTACHMENTS" << 'EOF'
import sys
import re
import os
import shutil
from html import unescape
from html.parser import HTMLParser
import gc

if len(sys.argv) < 6:
    sys.exit(1)

input_file = sys.argv[1]
temp_dir = sys.argv[2]
attachments_dir = sys.argv[3]
output_dir = sys.argv[4]
skip_attachments = sys.argv[5] == 'true'

# Dictionary to store page info by body content ID
page_info = {}
# Dictionary to store page title to filename mapping
title_to_filename = {}
# Dictionary to store attachment info
attachment_info = {}
# Dictionary to store the latest version of each page by title
latest_pages = {}
# Dictionary to store space info
space_info = {}
# Dictionary to store page to space mapping
page_to_space = {}
# Dictionary to store label info
label_info = {}
# Dictionary to store page labels
page_labels = {}
# Dictionary to store parent-child relationships
page_children = {}
# Dictionary to store page parent
page_parent = {}

# Custom HTML to Markdown converter
class HTML2Markdown(HTMLParser):
    def __init__(self):
        super().__init__()
        self.markdown = []
        self.current_tag = []
        self.list_stack = []
        self.list_counters = []
        self.table_rows = []
        self.table_row = []
        self.in_code_block = False
        self.code_language = ""
        self.code_content = []
        self.in_table = False
        self.in_table_cell = False
        self.current_cell_content = []
        self.in_list_item = False
        self.list_item_content = []
        self.in_blockquote = False
        self.list_marker = ""
        self.wikijs_macro_class = None
        
    def handle_starttag(self, tag, attrs):
        self.current_tag.append(tag)
        attrs_dict = dict(attrs)
        
        if tag in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
            level = int(tag[1])
            self.markdown.append('\n' + '#' * level + ' ')
        elif tag == 'p':
            if self.in_table_cell:
                # In table cells, add line break before new paragraphs (except the first one)
                if self.current_cell_content and self.current_cell_content[-1] not in ['', '<br>']:
                    self.current_cell_content.append('<br>')
            elif self.in_blockquote:
                # In blockquotes, add a new line with > prefix
                if self.markdown and self.markdown[-1] not in ['\n', '']:
                    self.markdown.append('\n> ')
            elif not self.in_list_item:
                self.markdown.append('\n\n')
        elif tag == 'br':
            if self.in_table_cell:
                self.current_cell_content.append('<br>')
            elif self.in_list_item:
                self.list_item_content.append('  \n')
            else:
                self.markdown.append('  \n')
        elif tag == 'strong' or tag == 'b':
            if self.in_table_cell:
                self.current_cell_content.append('**')
            elif self.in_list_item:
                self.list_item_content.append('**')
            else:
                self.markdown.append('**')
        elif tag == 'em' or tag == 'i':
            if self.in_table_cell:
                self.current_cell_content.append('*')
            elif self.in_list_item:
                self.list_item_content.append('*')
            else:
                self.markdown.append('*')
        elif tag == 'code':
            if 'pre' not in self.current_tag:
                if self.in_table_cell:
                    self.current_cell_content.append('`')
                elif self.in_list_item:
                    self.list_item_content.append('`')
                else:
                    self.markdown.append('`')
            # Check for language class in code tag
            if 'class' in attrs_dict and attrs_dict['class'].startswith('language-'):
                self.code_language = attrs_dict['class'].replace('language-', '')
        elif tag == 'pre':
            self.in_code_block = True
            self.code_content = []
            # Check for language in pre tag
            if 'class' in attrs_dict and attrs_dict['class'].startswith('language-'):
                self.code_language = attrs_dict['class'].replace('language-', '')
        elif tag == 'a':
            if self.in_list_item:
                self.list_item_content.append('[')
            elif self.in_table_cell:
                self.current_cell_content.append('[')
            elif not self.in_table:
                self.markdown.append('[')
            self._link_href = attrs_dict.get('href', '')
        elif tag == 'ul':
            self.list_stack.append('ul')
            if len(self.list_stack) == 1:
                self.markdown.append('\n')
        elif tag == 'ol':
            self.list_stack.append('ol')
            # Check for start attribute
            start_value = 1  # default start value
            if 'start' in attrs_dict:
                try:
                    start_value = int(attrs_dict['start'])
                except ValueError:
                    start_value = 1
            # Initialize counter to start_value - 1 (will be incremented when we hit the first li)
            self.list_counters.append(start_value - 1)
            if len(self.list_stack) == 1:
                self.markdown.append('\n')
        elif tag == 'li':
            self.in_list_item = True
            self.list_item_content = []
            indent = '  ' * (len(self.list_stack) - 1)
            if self.in_table_cell:
                # In table cells, add line break before list items
                if self.current_cell_content and self.current_cell_content[-1] not in ['', '<br>']:
                    self.current_cell_content.append('<br>')
                # Use appropriate list marker
                if self.list_stack and self.list_stack[-1] == 'ol':
                    self.list_counters[-1] += 1
                    self.current_cell_content.append(f'{self.list_counters[-1]}. ')
                else:
                    self.current_cell_content.append('• ')
            else:
                # Store the list marker to be added when we have content
                if 'class' in attrs_dict and 'task-list-item' in attrs_dict.get('class', ''):
                    self.list_marker = f'\n{indent}- '
                elif self.list_stack and self.list_stack[-1] == 'ol':
                    # Increment counter for ordered lists
                    self.list_counters[-1] += 1
                    self.list_marker = f'\n{indent}{self.list_counters[-1]}. '
                else:
                    self.list_marker = f'\n{indent}- '
        elif tag == 'table':
            self.markdown.append('\n\n')
            self.table_rows = []
            self.in_table = True
        elif tag == 'tr':
            self.table_row = []
        elif tag in ['td', 'th']:
            self.in_table_cell = True
            self.current_cell_content = []
        elif tag == 'hr':
            self.markdown.append('\n\n---\n\n')
        elif tag == 'blockquote':
            self.markdown.append('\n\n> ')
            self.in_blockquote = True
        elif tag == 'div':
            # Check if this is a Wiki.js macro div
            if 'class' in attrs_dict and attrs_dict['class'].startswith('wikijs-macro-'):
                self.in_blockquote = True
                self.markdown.append('\n\n> ')
                # Store the class for later use when closing the div
                self.wikijs_macro_class = attrs_dict['class'].replace('wikijs-macro-', '')
        elif tag == 'img':
            # Add newline before standalone images (not in tables)
            if not self.in_table_cell:
                self.markdown.append('\n')
            # Handle image tags
            src = attrs_dict.get('src', '')
            alt = attrs_dict.get('alt', '')
            # Check for width/height attributes
            width = attrs_dict.get('width', '')
            height = attrs_dict.get('height', '')
            
            img_markdown = f'![{alt}]({src}'
            if width:
                img_markdown += f' ={width}x'
            elif height:
                img_markdown += f' =x{height}'
            img_markdown += ')'
            
            if self.in_table_cell:
                self.current_cell_content.append(img_markdown)
            else:
                self.markdown.append(img_markdown)
            
    def handle_endtag(self, tag):
        if self.current_tag and self.current_tag[-1] == tag:
            self.current_tag.pop()
            
        if tag in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
            self.markdown.append('\n')
        elif tag == 'p':
            if self.in_list_item:
                # Don't add extra newlines in list items
                pass
            elif not self.in_table_cell:
                pass
        elif tag == 'strong' or tag == 'b':
            if self.in_table_cell:
                self.current_cell_content.append('**')
            elif self.in_list_item:
                self.list_item_content.append('**')
            else:
                self.markdown.append('**')
        elif tag == 'em' or tag == 'i':
            if self.in_table_cell:
                self.current_cell_content.append('*')
            elif self.in_list_item:
                self.list_item_content.append('*')
            else:
                self.markdown.append('*')
        elif tag == 'code':
            if 'pre' not in self.current_tag:
                if self.in_table_cell:
                    self.current_cell_content.append('`')
                elif self.in_list_item:
                    self.list_item_content.append('`')
                else:
                    self.markdown.append('`')
        elif tag == 'pre':
            # Write the complete code block
            self.markdown.append(f'\n\n```{self.code_language}\n')
            self.markdown.append(''.join(self.code_content))
            self.markdown.append('\n```\n')
            self.in_code_block = False
            self.code_language = ""
            self.code_content = []
        elif tag == 'a':
            if self.in_list_item:
                self.list_item_content.append(f']({self._link_href})')
            elif self.in_table_cell:
                self.current_cell_content.append(f']({self._link_href})')
            elif not self.in_table:
                self.markdown.append(f']({self._link_href})')
        elif tag == 'ul':
            if self.list_stack:
                self.list_stack.pop()
            if not self.list_stack:
                self.markdown.append('\n')
        elif tag == 'ol':
            if self.list_stack:
                self.list_stack.pop()
            if self.list_counters:
                self.list_counters.pop()
            if not self.list_stack:
                self.markdown.append('\n')
        elif tag == 'li':
            # Add list item content to markdown
            if self.list_item_content:
                content = ''.join(self.list_item_content).strip()
                if self.in_table_cell:
                    self.current_cell_content.append(content)
                else:
                    # Add the list marker first, then the content
                    if hasattr(self, 'list_marker'):
                        self.markdown.append(self.list_marker)
                        self.markdown.append(content)
                    else:
                        # Fallback if list_marker wasn't set
                        self.markdown.append(content)
            self.in_list_item = False
            self.list_item_content = []
        elif tag == 'table':
            if self.table_rows:
                # First row as header
                self.markdown.append('| ' + ' | '.join(self.table_rows[0]) + ' |\n')
                # Create separator row with left-aligned first column
                separators = []
                for i in range(len(self.table_rows[0])):
                    if i == 0:
                        separators.append(':---')  # Left-align first column
                    else:
                        separators.append('---')   # Default alignment for other columns
                self.markdown.append('|' + '|'.join(separators) + '|\n')
                # Rest as data
                for row in self.table_rows[1:]:
                    self.markdown.append('| ' + ' | '.join(row) + ' |\n')
                self.markdown.append('\n')
            self.in_table = False
        elif tag == 'tr':
            if self.table_row:
                self.table_rows.append(self.table_row)
        elif tag in ['td', 'th']:
            # Join all content in the cell
            cell_content = ''.join(self.current_cell_content).strip()
            # Replace <br> tags with actual line breaks
            cell_content = cell_content.replace('<br>', '<br />')
            # Escape pipe characters
            cell_content = cell_content.replace('|', '\\|')
            self.table_row.append(cell_content)
            self.in_table_cell = False
            self.current_cell_content = []
        elif tag == 'blockquote':
            self.in_blockquote = False
        elif tag == 'div':
            # Check if this was a Wiki.js macro div
            if self.wikijs_macro_class:
                self.in_blockquote = False
                # Add the Wiki.js class notation
                self.markdown.append(f'\n{{{self.wikijs_macro_class}}}\n')
                self.wikijs_macro_class = None
                
    def handle_data(self, data):
        if self.in_table_cell:
            # Accumulate all content within table cells
            self.current_cell_content.append(data)
        elif self.in_code_block:
            self.code_content.append(data)
        elif self.in_list_item:
            self.list_item_content.append(data)
        elif self.in_blockquote:
            # Handle blockquote data - need to add > for each new line
            lines = data.split('\n')
            for i, line in enumerate(lines):
                if i > 0:
                    self.markdown.append('\n> ')
                self.markdown.append(line)
        elif not self.in_table:
            # Only append to markdown if not inside a table
            self.markdown.append(data)
        # If we're in a table but not in a cell, ignore the data
                
    def get_markdown(self):
        result = ''.join(self.markdown)
        # Clean up excessive newlines
        result = re.sub(r'\n{3,}', '\n\n', result)
        # Clean up spacing in lists
        result = re.sub(r'\n-\s*\n\n', '\n- ', result)
        result = re.sub(r'\n\d+\.\s*\n\n', '\n1. ', result)
        return result.strip()

def html_to_markdown(html):
    """Convert HTML to Markdown"""
    parser = HTML2Markdown()
    parser.feed(html)
    return parser.get_markdown()

# Read the XML file
print("Reading XML file...")
with open(input_file, 'r', encoding='utf-8') as f:
    content = f.read()

# Extract Space objects first to get space keys
print("Extracting spaces...")
space_pattern = r'<object class="Space" package="com\.atlassian\.confluence\.spaces">.*?</object>'
spaces = re.findall(space_pattern, content, re.DOTALL)

for space in spaces:
    # Extract space ID
    space_id_match = re.search(r'<id name="id">(\d+)</id>', space)
    if not space_id_match:
        continue
    space_id = space_id_match.group(1)
    
    # Extract space key
    key_match = re.search(r'<property name="key"><!\[CDATA\[(.*?)\]\]></property>', space)
    if not key_match:
        continue
    space_key = key_match.group(1)
    
    # Extract space name
    name_match = re.search(r'<property name="name"><!\[CDATA\[(.*?)\]\]></property>', space)
    space_name = name_match.group(1) if name_match else space_key
    
    space_info[space_id] = {
        'key': space_key,
        'name': space_name
    }
    
print(f"Found {len(space_info)} spaces")

# Extract all Label objects
print("Extracting labels...")
label_pattern = r'<object class="Label" package="com\\.atlassian\\.confluence\\.labels">.*?</object>'
labels = re.findall(label_pattern, content, re.DOTALL)

for label in labels:
    # Extract label ID
    label_id_match = re.search(r'<id name="id">(\\d+)</id>', label)
    if not label_id_match:
        continue
    label_id = label_id_match.group(1)
    
    # Extract label name
    name_match = re.search(r'<property name="name"><!\\[CDATA\\[(.*?)\\]\\]></property>', label)
    if not name_match:
        continue
    label_name = name_match.group(1)
    
    label_info[label_id] = label_name

print(f"Found {len(label_info)} labels")

# Extract all Labelling objects (links between pages and labels)
print("Extracting label assignments...")
labelling_pattern = r'<object class="Labelling" package="com\\.atlassian\\.confluence\\.labels">.*?</object>'
labellings = re.findall(labelling_pattern, content, re.DOTALL)

for labelling in labellings:
    # Extract content (page) ID
    content_match = re.search(r'<property name="content" class="Page".*?<id name="id">(\\d+)</id>', labelling, re.DOTALL)
    if not content_match:
        continue
    page_id = content_match.group(1)
    
    # Extract label ID
    label_match = re.search(r'<property name="label" class="Label".*?<id name="id">(\\d+)</id>', labelling, re.DOTALL)
    if not label_match:
        continue
    label_id = label_match.group(1)
    
    # Add label to page
    if page_id not in page_labels:
        page_labels[page_id] = []
    
    if label_id in label_info:
        page_labels[page_id].append(label_info[label_id])

print(f"Found {len(page_labels)} pages with labels")

# Extract all Attachment objects
print("Extracting attachments...")
attachment_pattern = r'<object class="Attachment" package="com\.atlassian\.confluence\.pages">.*?</object>'
attachments = re.findall(attachment_pattern, content, re.DOTALL)

for attachment in attachments:
    # Extract attachment ID
    att_id_match = re.search(r'<id name="id">(\d+)</id>', attachment)
    if not att_id_match:
        continue
    att_id = att_id_match.group(1)
    
    # Extract attachment title (filename)
    title_match = re.search(r'<property name="title"><!\[CDATA\[(.*?)\]\]></property>', attachment)
    if not title_match:
        continue
    filename = title_match.group(1)
    
    # Extract container page ID
    container_match = re.search(r'<property name="containerContent" class="Page".*?<id name="id">(\d+)</id>', attachment, re.DOTALL)
    if not container_match:
        continue
    container_id = container_match.group(1)
    
    # Store attachment info by both filename and by ID
    if filename not in attachment_info:
        attachment_info[filename] = []
    attachment_info[filename].append({
        'id': att_id,
        'container_id': container_id,
        'filename': filename
    })
    
print(f"Found {len(attachment_info)} unique attachment filenames")

# Build a map of existing attachment paths for faster lookup
attachment_paths = {}
if not skip_attachments and os.path.exists(attachments_dir):
    print("Building attachment path index...")
    path_count = 0
    for container_dir in os.listdir(attachments_dir):
        container_path = os.path.join(attachments_dir, container_dir)
        if os.path.isdir(container_path):
            for att_dir in os.listdir(container_path):
                att_path = os.path.join(container_path, att_dir)
                if os.path.isdir(att_path):
                    file_path = os.path.join(att_path, '1')
                    if os.path.exists(file_path):
                        # Store both container_id/att_id and just att_id as keys
                        attachment_paths[f"{container_dir}/{att_dir}"] = file_path
                        attachment_paths[att_dir] = file_path
                        path_count += 1
                        if path_count % 10000 == 0:
                            print(f"  Indexed {path_count} attachment paths...")
    print(f"  Indexed {path_count} attachment file paths")

# Extract all Page objects
print("Extracting pages...")
page_pattern = r'<object class="Page" package="com\.atlassian\.confluence\.pages">.*?</object>'
pages = re.findall(page_pattern, content, re.DOTALL)

pages_count = 0
for page in pages:
    # Extract page ID
    page_id_match = re.search(r'<id name="id">(\d+)</id>', page)
    if not page_id_match:
        continue
    page_id = page_id_match.group(1)
    
    # Extract page title
    title_match = re.search(r'<property name="title"><!\[CDATA\[(.*?)\]\]></property>', page)
    if not title_match:
        continue
    page_title = title_match.group(1)
    
    # Extract version
    version_match = re.search(r'<property name="version">(\d+)</property>', page)
    version = int(version_match.group(1)) if version_match else 1
    
    # Extract space reference
    space_match = re.search(r'<property name="space" class="Space".*?<id name="id">(\d+)</id>', page, re.DOTALL)
    if space_match:
        space_id = space_match.group(1)
        page_to_space[page_id] = space_id
    
    # Only process if this is the latest version we've seen
    if page_title in latest_pages:
        if version <= latest_pages[page_title]['version']:
            continue
    
    # Extract additional metadata
    creation_date_match = re.search(r'<property name="creationDate">(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d+)</property>', page)
    creation_date = creation_date_match.group(1) if creation_date_match else None
    
    last_modified_match = re.search(r'<property name="lastModificationDate">(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d+)</property>', page)
    last_modified = last_modified_match.group(1) if last_modified_match else None
    
    # Extract creator username
    creator_match = re.search(r'<property name="creator" class="ConfluenceUserImpl".*?<property name="name"><!\[CDATA\[(.*?)\]\]></property>', page, re.DOTALL)
    creator = creator_match.group(1) if creator_match else None
    
    # Extract last modifier username  
    modifier_match = re.search(r'<property name="lastModifier" class="ConfluenceUserImpl".*?<property name="name"><!\[CDATA\[(.*?)\]\]></property>', page, re.DOTALL)
    last_modifier = modifier_match.group(1) if modifier_match else None
    
    # Extract parent page reference
    parent_match = re.search(r'<property name="parent" class="Page".*?<id name="id">(\d+)</id>', page, re.DOTALL)
    parent_id = parent_match.group(1) if parent_match else None
    
    # Extract children pages
    children_ids = []
    children_match = re.search(r'<collection name="childrens".*?>(.*?)</collection>', page, re.DOTALL)
    if children_match:
        children_content = children_match.group(1)
        children_ids = re.findall(r'<element class="Page".*?<id name="id">(\d+)</id>', children_content, re.DOTALL)
    
    # Store parent-child relationships
    if parent_id:
        page_parent[page_id] = parent_id
    
    if children_ids:
        page_children[page_id] = children_ids
    
    latest_pages[page_title] = {
        'version': version,
        'page_id': page_id,
        'page_object': page,
        'creation_date': creation_date,
        'last_modified': last_modified,
        'creator': creator,
        'last_modifier': last_modifier,
        'parent_id': parent_id,
        'children_ids': children_ids
    }
    
    pages_count += 1
    if pages_count % 100 == 0:
        print(f"Processed {pages_count} pages...")

print(f"Found {pages_count} pages, {len(latest_pages)} unique titles")

# Build complete parent-child relationships from both directions
print("Building complete parent-child relationships...")
for page_title, page_data in latest_pages.items():
    page_id = page_data['page_id']
    parent_id = page_data.get('parent_id')
    
    # If this page has a parent, ensure the parent knows about this child
    if parent_id:
        # Find the parent page in latest_pages
        parent_found = False
        for parent_title, parent_data in latest_pages.items():
            if parent_data['page_id'] == parent_id:
                parent_found = True
                # Add this page as a child if not already there
                if parent_id not in page_children:
                    page_children[parent_id] = []
                if page_id not in page_children[parent_id]:
                    page_children[parent_id].append(page_id)
                break
        
        if not parent_found:
            print(f"  Warning: Parent page {parent_id} not found in latest pages for child {page_title} ({page_id})")

# Now process only the latest versions
for page_title, page_data in latest_pages.items():
    page_id = page_data['page_id']
    page = page_data['page_object']
    
    # Extract body content ID references
    body_refs = re.findall(r'<element class="BodyContent".*?<id name="id">(\d+)</id>', page, re.DOTALL)
    
    # Use only page ID as filename
    filename = page_id
    
    # Store title to filename mapping
    title_to_filename[page_title] = filename
    
    for body_id in body_refs:
        page_info[body_id] = {
            'page_id': page_id,
            'title': page_title,
            'filename': filename
        }

# Function to fix internal links
def fix_internal_links(html_content, current_page_space_key):
    # First, handle regular Confluence edit URLs
    # Pattern to match: https://tecnologiaeinnovacion.atlassian.net/wiki/spaces/{space_id}/pages/edit-v2/{page_id}/
    # Replace Confluence edit URLs
    # Match both cases: with link text and without (where href becomes the text)
    confluence_url_pattern = r'<a[^>]*href="(https://[^/]+/wiki/spaces/\d+/pages/edit-v2/(\d+)/?)"[^>]*>([^<]*)</a>'
    def replace_confluence_url_with_groups(match):
        full_url = match.group(1)
        page_id = match.group(2)
        link_text = match.group(3)
        
        # If link text is empty or is the URL itself, we need to find the page title
        if not link_text or link_text == full_url:
            # Find page title
            page_title = None
            for title, pid in title_to_filename.items():
                if pid == page_id:
                    page_title = title
                    break
            link_text = page_title if page_title else f"Page {page_id}"
        
        # Check if we have info about this page ID
        if page_id in page_to_space:
            space_id = page_to_space[page_id]
            if space_id in space_info:
                space_key = space_info[space_id]['key']
            else:
                space_key = current_page_space_key
        else:
            space_key = current_page_space_key
        
        return f'<a href="/wiki/spaces/{space_key}/pages/{page_id}">{link_text}</a>'
    
    html_content = re.sub(confluence_url_pattern, replace_confluence_url_with_groups, html_content, flags=re.IGNORECASE)
    
    # Also handle plain URLs (not in anchor tags)
    plain_url_pattern = r'https://[^/]+/wiki/spaces/\d+/pages/edit-v2/(\d+)/?'
    def replace_plain_url(match):
        page_id = match.group(1)
        
        # Check if we have info about this page ID
        if page_id in page_to_space:
            space_id = page_to_space[page_id]
            if space_id in space_info:
                space_key = space_info[space_id]['key']
            else:
                space_key = current_page_space_key
        else:
            space_key = current_page_space_key
        
        # Find page title if we have it
        page_title = None
        for title, pid in title_to_filename.items():
            if pid == page_id:
                page_title = title
                break
        
        link_text = page_title if page_title else f"Page {page_id}"
        return f'[{link_text}](/wiki/spaces/{space_key}/pages/{page_id})'
    
    # First check if this is inside an anchor tag to avoid double processing
    # Split by <a> tags and process only non-anchor parts
    parts = re.split(r'(<a[^>]*>.*?</a>)', html_content, flags=re.DOTALL)
    for i in range(len(parts)):
        # Only process parts that are not anchor tags
        if not parts[i].startswith('<a'):
            parts[i] = re.sub(plain_url_pattern, replace_plain_url, parts[i])
    html_content = ''.join(parts)
    
    # Pattern to find Confluence internal page links
    # <ac:link><ri:page ri:content-title="Title"/><ac:link-body>Link Text</ac:link-body></ac:link>
    def replace_link(match):
        linked_page_title = match.group(1)
        link_text = match.group(2) if match.group(2) else linked_page_title
        
        if linked_page_title in title_to_filename:
            linked_page_id = title_to_filename[linked_page_title]
            
            # Get space key for the linked page
            linked_space_id = page_to_space.get(linked_page_id)
            if linked_space_id and linked_space_id in space_info:
                linked_space_key = space_info[linked_space_id]['key']
            else:
                # Default to current page's space if not found
                linked_space_key = current_page_space_key
            
            return f'<a href="/wiki/spaces/{linked_space_key}/pages/{linked_page_id}">{link_text}</a>'
        else:
            return link_text
    
    # Complex pattern for various link formats
    patterns = [
        # Pattern with link body
        (r'<ac:link[^>]*>.*?<ri:page[^>]*ri:content-title="([^"]+)"[^>]*/>.*?<ac:link-body>([^<]+)</ac:link-body>.*?</ac:link>', 2),
        # Pattern without link body
        (r'<ac:link[^>]*>.*?<ri:page[^>]*ri:content-title="([^"]+)"[^>]*/>.*?</ac:link>', 1),
    ]
    
    for pattern, groups in patterns:
        if groups == 2:
            html_content = re.sub(pattern, replace_link, html_content, flags=re.DOTALL)
        else:
            html_content = re.sub(pattern, 
                lambda m: f'<a href="/wiki/spaces/{current_page_space_key}/pages/{title_to_filename.get(m.group(1), m.group(1))}">{m.group(1)}</a>' 
                if m.group(1) in title_to_filename else m.group(1), 
                html_content, flags=re.DOTALL)
    
    return html_content

# Function to sanitize attachment filenames
def sanitize_filename(filename):
    """Clean filename for safe storage and compatibility"""
    import unicodedata
    
    # Special handling for media-blob-url images (clipboard pastes)
    if 'media-blob-url' in filename:
        # Extract the UUID at the beginning if present
        uuid_match = re.match(r'^([a-f0-9\-]+)', filename)
        if uuid_match:
            base_name = uuid_match.group(1)
        else:
            # Fallback to a hash of the filename
            import hashlib
            base_name = hashlib.md5(filename.encode()).hexdigest()[:12]
        
        # These are typically screenshots/clipboard images, so use .png
        return f"{base_name}_media-blob.png"
    
    # First, normalize unicode and remove accents
    # Decompose unicode characters (e.g., á -> a + ´)
    nfd_form = unicodedata.normalize('NFD', filename)
    # Filter out combining characters (accents)
    filename_clean = ''.join(char for char in nfd_form if unicodedata.category(char) != 'Mn')
    
    # Replace specific characters with underscore
    special_chars = [')', '[', ']', '(', '&', '/', '\\', '!', '#', '$', '%', '=', '{', '}']
    for char in special_chars:
        filename_clean = filename_clean.replace(char, '_')
    
    # Check if file has no extension and appears to be an image
    has_extension = '.' in filename_clean and filename_clean.rsplit('.', 1)[1].lower() in [
        'jpg', 'jpeg', 'png', 'gif', 'bmp', 'svg', 'webp', 'ico', 'tiff', 'tif'
    ]
    
    # Replace multiple dots with single dot (except for file extension)
    # Split filename and extension
    if '.' in filename_clean:
        name_parts = filename_clean.rsplit('.', 1)
        name = name_parts[0]
        ext = name_parts[1]
        # Remove dots from the name part
        name = name.replace('.', '_')
        # Remove trailing underscores before extension
        name = name.rstrip('_')
        filename_clean = f"{name}.{ext}"
    else:
        # No extension - if it looks like an image-related name, add .png
        if any(indicator in filename_clean.lower() for indicator in ['image', 'screenshot', 'picture', 'img']):
            filename_clean = f"{filename_clean}.png"
    
    # Replace multiple underscores with single underscore
    while '__' in filename_clean:
        filename_clean = filename_clean.replace('__', '_')
    
    # Replace spaces with underscores (as before)
    filename_clean = filename_clean.replace(' ', '_')
    
    return filename_clean

# Function to copy attachment if it exists
def copy_attachment(att_filename, page_id, dest_path, att_id=None):
    if skip_attachments:
        # Just return True to indicate we're skipping but it's OK
        return True
    
    # Debug: print what we're looking for
    print(f"  Looking for attachment: {att_filename} (Page: {page_id}, Att ID: {att_id})")
    
    # Check pre-built index first (fastest)
    if att_id:
        # Try container_id/att_id first
        key = f"{page_id}/{att_id}"
        if key in attachment_paths:
            try:
                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                shutil.copy2(attachment_paths[key], dest_path)
                print(f"  Copied attachment: {att_filename} -> {dest_path}")
                return True
            except Exception as e:
                print(f"  Error copying attachment {att_filename}: {e}")
        
        # Try just att_id
        if att_id in attachment_paths:
            try:
                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                shutil.copy2(attachment_paths[att_id], dest_path)
                print(f"  Copied attachment: {att_filename} -> {dest_path}")
                return True
            except Exception as e:
                print(f"  Error copying attachment {att_filename}: {e}")
        
        print(f"  WARNING: Attachment not found in index. Keys tried: '{key}', '{att_id}'")
    
    # If not in index, attachment doesn't exist in filesystem
    return False

# Function to convert Confluence macros to HTML
def convert_confluence_macros(html_content, page_id, space_key):
    # Convert code blocks - handle double CDATA nesting
    def replace_code(match):
        full_match = match.group(0)
        
        # Extract language parameter
        lang_match = re.search(r'<ac:parameter[^>]*ac:name="language">([^<]*)</ac:parameter>', full_match)
        language = lang_match.group(1) if lang_match else ''
        
        # For code blocks, we need to extract the content inside the inner CDATA
        # Look for pattern: <ac:plain-text-body><![CDATA[...content...]]></ac:plain-text-body>
        # But since this is inside another CDATA, the ]] is escaped as ]]]]><![CDATA[>
        
        # Find the start and end of the code content
        plain_text_start = full_match.find('<ac:plain-text-body><![CDATA[')
        if plain_text_start >= 0:
            # Move past the opening tag
            content_start = plain_text_start + len('<ac:plain-text-body><![CDATA[')
            
            # Find the closing tag - but handle the nested CDATA case
            # In nested CDATA, ]] becomes ]]]]><![CDATA[>
            # Also handle cases where there might be spaces before the closing >
            content_end = full_match.find(']]></ac:plain-text-body>', content_start)
            if content_end == -1:
                # Try with space before closing bracket
                content_end = full_match.find(']] ></ac:plain-text-body>', content_start)
            
            if content_end > content_start:
                code = full_match[content_start:content_end]
                
                # Handle the special case where ]] in the code is escaped as ]]]]><![CDATA[>
                code = code.replace(']]]]><![CDATA[>', ']]')
                
                # Don't parse as HTML - keep raw content
                # Just escape HTML special characters for safety
                code = code.replace('&', '&amp;')
                code = code.replace('<', '&lt;')
                code = code.replace('>', '&gt;')
                
                return f'<pre><code class="language-{language}">{code}</code></pre>'
        
        # Fallback: try simpler extraction
        simple_match = re.search(r'<ac:plain-text-body><!\[CDATA\[(.*?)\]\]></ac:plain-text-body>', full_match, re.DOTALL)
        if simple_match:
            code = simple_match.group(1)
            # Don't parse as HTML - keep raw content
            code = code.replace('&', '&amp;')
            code = code.replace('<', '&lt;')
            code = code.replace('>', '&gt;')
            return f'<pre><code class="language-{language}">{code}</code></pre>'
            
        return '<pre><code></code></pre>'
    
    # Pattern to match code macros
    code_pattern = r'<ac:structured-macro[^>]*ac:name="code"[^>]*>.*?</ac:structured-macro>'
    html_content = re.sub(code_pattern, replace_code, html_content, flags=re.DOTALL)
    
    # Convert info/note/warning/error/success macros
    def replace_info_macros(match):
        full_match = match.group(0)
        
        # Extract the macro type (info, note, warning, error, success)
        type_match = re.search(r'ac:name="(info|note|warning|error|success)"', full_match)
        if not type_match:
            return full_match
        
        macro_type = type_match.group(1)
        
        # Extract the body content
        body_match = re.search(r'<ac:rich-text-body>(.*?)</ac:rich-text-body>', full_match, re.DOTALL)
        if not body_match:
            return full_match
        
        body_content = body_match.group(1)
        
        # Map Confluence macro types to Wiki.js classes
        type_mapping = {
            'info': 'is-info',
            'note': 'is-info',
            'warning': 'is-warning',
            'error': 'is-danger',
            'success': 'is-success'
        }
        
        wiki_class = type_mapping.get(macro_type, 'is-info')
        
        # Create a blockquote div with the appropriate class
        return f'<div class="wikijs-macro-{wiki_class}">{body_content}</div>'
    
    # Pattern to match info/note/warning/error/success macros
    info_pattern = r'<ac:structured-macro[^>]*ac:name="(?:info|note|warning|error|success)"[^>]*>.*?</ac:structured-macro>'
    html_content = re.sub(info_pattern, replace_info_macros, html_content, flags=re.DOTALL)
    
    # Convert ADF panel macros (note, info, warning, etc. in newer Confluence format)
    def replace_adf_panels(match):
        full_match = match.group(0)
        
        # Extract the panel type
        type_match = re.search(r'<ac:adf-attribute key="panel-type">(.*?)</ac:adf-attribute>', full_match)
        if not type_match:
            return full_match
        
        panel_type = type_match.group(1)
        
        # Extract the content from ac:adf-content
        content_match = re.search(r'<ac:adf-content>(.*?)</ac:adf-content>', full_match, re.DOTALL)
        if not content_match:
            # Try to extract from the fallback div if ac:adf-content is not found
            content_match = re.search(r'<div class="panelContent"[^>]*>(.*?)</div></div></ac:adf-fallback>', full_match, re.DOTALL)
            if not content_match:
                return full_match
        
        content = content_match.group(1)
        
        # Map panel types to Wiki.js classes
        type_mapping = {
            'info': 'is-info',
            'note': 'is-info',
            'warning': 'is-warning',
            'error': 'is-danger',
            'success': 'is-success',
            'tip': 'is-success'
        }
        
        wiki_class = type_mapping.get(panel_type, 'is-info')
        
        # Create a blockquote div with the appropriate class
        return f'<div class="wikijs-macro-{wiki_class}">{content}</div>'
    
    # Pattern to match ADF panels
    adf_pattern = r'<ac:adf-extension>.*?<ac:adf-node type="panel">.*?</ac:adf-extension>'
    html_content = re.sub(adf_pattern, replace_adf_panels, html_content, flags=re.DOTALL)
    
    # Convert task lists
    def replace_task(match):
        full_match = match.group(0)
        # Extract task status
        status_match = re.search(r'<ac:task-status>(complete|incomplete)</ac:task-status>', full_match)
        # Extract task body
        body_match = re.search(r'<ac:task-body>(.*?)</ac:task-body>', full_match, re.DOTALL)
        
        if status_match and body_match:
            status = status_match.group(1)
            body = body_match.group(1)
            
            # Clean up the body content
            body = re.sub(r'<span[^>]*>', '', body)
            body = re.sub(r'</span>', '', body)
            body = re.sub(r'<strong>\s*</strong>', '', body)
            body = body.strip()
            
            # Convert to markdown task syntax
            checkbox = '[x]' if status == 'complete' else '[ ]'
            return f'<li class="task-list-item">{checkbox} {body}</li>'
        
        return ''
    
    # Replace task lists
    task_pattern = r'<ac:task>.*?</ac:task>'
    html_content = re.sub(task_pattern, replace_task, html_content, flags=re.DOTALL)
    
    # Convert task-list tags to ul tags
    html_content = html_content.replace('<ac:task-list>', '<ul class="task-list">')
    html_content = html_content.replace('</ac:task-list>', '</ul>')
    
    # Convert Roadmap Planner macro
    def replace_roadmap_planner(match):
        full_match = match.group(0)
        
        # Extract the source parameter which contains the encoded data
        source_match = re.search(r'<ac:parameter[^>]*ac:name="source">\\s*([^<]+)\\s*</ac:parameter>', full_match, re.DOTALL)
        if not source_match:
            return '[Roadmap Planner - Could not extract data]'
        
        encoded_data = source_match.group(1).strip()
        
        # Check if this looks like URL-encoded JSON (starts with %7B which is {)
        if encoded_data.startswith('%7B'):
            try:
                # URL decode the data
                import urllib.parse
                decoded_data = urllib.parse.unquote(encoded_data)
                
                # Parse as JSON
                import json
                roadmap_data = json.loads(decoded_data)
                
                # Create a simple text representation
                result = ['## Roadmap: ' + roadmap_data.get('title', 'Untitled Roadmap')]
                result.append('')
                
                # Add timeline info
                timeline = roadmap_data.get('timeline', {})
                start_date = timeline.get('startDate', '').split(' ')[0]
                end_date = timeline.get('endDate', '').split(' ')[0]
                if start_date and end_date:
                    result.append(f'**Timeline:** {start_date} to {end_date}')
                    result.append('')
                
                # Add lanes and their features
                for lane in roadmap_data.get('lanes', []):
                    result.append(f"### {lane.get('title', 'Untitled Lane')}")
                    result.append('')
                    
                    bars = sorted(lane.get('bars', []), key=lambda x: x.get('startDate', ''))
                    for bar in bars:
                        feature_name = bar.get('title', 'Untitled Feature')
                        start = bar.get('startDate', '').split(' ')[0]
                        duration = bar.get('duration', 0)
                        description = bar.get('description', '')
                        
                        result.append(f"- **{feature_name}**")
                        if start:
                            result.append(f"  - Start: {start}")
                        if duration:
                            result.append(f"  - Duration: ~{int(duration)} months")
                        if description:
                            result.append(f"  - Description: {description}")
                    result.append('')
                
                # Add milestones
                milestones = roadmap_data.get('markers', [])
                if milestones:
                    result.append('### Milestones')
                    result.append('')
                    for milestone in sorted(milestones, key=lambda x: x.get('markerDate', '')):
                        title = milestone.get('title', 'Untitled Milestone')
                        date = milestone.get('markerDate', '').split(' ')[0]
                        if date:
                            result.append(f"- **{title}**: {date}")
                        else:
                            result.append(f"- **{title}**")
                    result.append('')
                
                result.append('> ℹ️ *This roadmap was converted from a Confluence Roadmap Planner macro. The original interactive timeline view is not available in this format.*')
                result.append('{.is-info}')
                
                return '\\n'.join(result)
                
            except Exception as e:
                # If parsing fails, add a note
                return f'[Roadmap Planner - Data could not be parsed]\\n\\n> ⚠️ *The Confluence Roadmap Planner macro contains interactive timeline data that cannot be automatically converted to static markdown. Consider creating a visual representation manually or taking a screenshot from the original Confluence page.*\\n{{.is-warning}}'
        
        return '[Roadmap Planner - Unknown format]'
    
    # Pattern to match roadmap macros
    roadmap_pattern = r'<ac:structured-macro[^>]*ac:name="roadmap"[^>]*>.*?</ac:structured-macro>'
    html_content = re.sub(roadmap_pattern, replace_roadmap_planner, html_content, flags=re.DOTALL)
    
    # Convert JIRA macros
    def replace_jira_macro(match):
        full_match = match.group(0)
        
        # Extract JIRA key
        key_match = re.search(r'<ac:parameter[^>]*ac:name="key">([^<]+)</ac:parameter>', full_match)
        if not key_match:
            return '[JIRA link - key not found]'
        
        jira_key = key_match.group(1).strip()
        
        # Use the new JIRA URL format
        jira_url = f"https://proyectos.cic.cl/easy_tags/{jira_key}"
        
        return f'[JIRA {jira_key}]({jira_url})'
    
    # Pattern to match JIRA macros
    jira_pattern = r'<ac:structured-macro[^>]*ac:name="jira"[^>]*>.*?</ac:structured-macro>'
    html_content = re.sub(jira_pattern, replace_jira_macro, html_content, flags=re.DOTALL)
    
    # Replace existing JIRA links in HTML
    # Pattern to match: https://tecnologiaeinnovacion.atlassian.net/browse/XXX-123
    # Also handle cases where issue ID contains lowercase letters or just project key
    jira_link_pattern = r'https://tecnologiaeinnovacion\.atlassian\.net/browse/([A-Za-z0-9-]+)'
    def replace_jira_link(match):
        issue_key = match.group(1)
        # Only replace if it looks like a valid JIRA issue key
        # Updated pattern to handle cases like CONT2023-3992
        if re.match(r'^[A-Za-z]+\d*-\d+$', issue_key):
            return f'https://proyectos.cic.cl/easy_tags/{issue_key}'
        else:
            # Keep original URL if it doesn't match JIRA issue pattern
            return match.group(0)
    
    html_content = re.sub(jira_link_pattern, replace_jira_link, html_content)
    
    # Post-process HTML to ensure external links are properly formatted
    # This catches any remaining external links that might not be in macros
    def enhance_external_links(html):
        # Enhance MIRO links
        html = re.sub(
            r'<a[^>]*href="(https://miro\.com/[^"]+)"[^>]*>([^<]+)</a>',
            lambda m: f'<a href="{m.group(1)}">[MIRO Board] {m.group(2)}</a>',
            html
        )
        
        # Enhance other common external services if needed
        # Add more patterns here as needed
        
        return html
    
    html_content = enhance_external_links(html_content)
    
    # Convert images
    def replace_image(match):
        full_match = match.group(0)
        # Extract filename
        filename_match = re.search(r'<ri:attachment[^>]*ri:filename="([^"]+)"', full_match)
        if filename_match:
            img_filename = filename_match.group(1)
            # Unescape HTML entities in filename
            img_filename = unescape(img_filename)
            
            # Extract width and height from ac:image tag
            width_match = re.search(r'ac:width="(\d+)"', full_match)
            height_match = re.search(r'ac:original-height="(\d+)"', full_match)
            custom_width_match = re.search(r'ac:custom-width="true"', full_match)
            
            width = width_match.group(1) if width_match and custom_width_match else None
            height = height_match.group(1) if height_match and not custom_width_match else None
            
            # Look up attachment info
            att_id = None
            if img_filename in attachment_info:
                # Find the attachment that belongs to this page
                for att in attachment_info[img_filename]:
                    if att['container_id'] == page_id:
                        att_id = att['id']
                        break
                # If not found for this page, use the first one
                if not att_id and attachment_info[img_filename]:
                    att_id = attachment_info[img_filename][0]['id']
            
            # Generate attachment path
            if att_id:
                # Use simpler path structure: /attachments/{page_id}/{att_id}/{filename}
                # Use sanitized filename for the destination path
                url_filename = sanitize_filename(img_filename)
                dest_path = os.path.join(output_dir, "attachments", page_id, att_id, url_filename)
                
                if copy_attachment(img_filename, page_id, dest_path, att_id):
                    # Return HTML image tag that will be converted to markdown later
                    img_tag = f'<img src="/attachments/{page_id}/{att_id}/{url_filename}" alt="{img_filename}"'
                    if width:
                        img_tag += f' width="{width}"'
                    if height:
                        img_tag += f' height="{height}"'
                    img_tag += ' />'
                    return img_tag
                else:
                    return f'[Image: {img_filename} (not found)]'
            else:
                return f'[Image: {img_filename} (not found)]'
        return '[Image]'
    
    image_pattern = r'<ac:image[^>]*>.*?<ri:attachment[^>]*ri:filename="[^"]+"[^>]*/>.*?</ac:image>'
    html_content = re.sub(image_pattern, replace_image, html_content, flags=re.DOTALL)
    
    # Convert file attachments
    def replace_file(match):
        full_match = match.group(0)
        # Extract filename
        filename_match = re.search(r'<ri:attachment[^>]*ri:filename="([^"]+)"', full_match)
        if filename_match:
            att_filename = filename_match.group(1)
            # Unescape HTML entities in filename
            att_filename = unescape(att_filename)
            
            # Look up attachment info
            att_id = None
            if att_filename in attachment_info:
                # Find the attachment that belongs to this page
                for att in attachment_info[att_filename]:
                    if att['container_id'] == page_id:
                        att_id = att['id']
                        break
                # If not found for this page, use the first one
                if not att_id and attachment_info[att_filename]:
                    att_id = attachment_info[att_filename][0]['id']
            
            # Generate attachment path
            if att_id:
                # Use simpler path structure: /attachments/{page_id}/{att_id}/{filename}
                # Use sanitized filename for the destination path
                url_filename = sanitize_filename(att_filename)
                dest_path = os.path.join(output_dir, "attachments", page_id, att_id, url_filename)
                
                if copy_attachment(att_filename, page_id, dest_path, att_id):
                    # Return markdown link syntax
                    return f'[{att_filename}](/attachments/{page_id}/{att_id}/{url_filename})'
                else:
                    return f'[Attachment: {att_filename} (not found)]'
            else:
                return f'[Attachment: {att_filename} (not found)]'
        return '[Attachment]'
    
    file_pattern = r'<ac:structured-macro[^>]*ac:name="view-file"[^>]*>.*?<ri:attachment[^>]*ri:filename="[^"]+"[^>]*/>.*?</ac:structured-macro>'
    html_content = re.sub(file_pattern, replace_file, html_content, flags=re.DOTALL)
    
    # Convert attachments macro (displays all page attachments)
    def replace_attachments_macro(match):
        # Find all attachments for this page
        page_attachments = []
        if page_id in attachment_info:
            # This means the page_id is actually a filename, so we need to look differently
            pass
        
        # Look through all attachments to find ones belonging to this page
        for filename, att_list in attachment_info.items():
            for att in att_list:
                if att['container_id'] == page_id:
                    page_attachments.append({
                        'filename': filename,
                        'id': att['id']
                    })
        
        if page_attachments:
            # Generate a list of attachment links
            attachment_links = []
            attachment_links.append("\n\n## Attachments")
            attachment_links.append("")
            
            for att in sorted(page_attachments, key=lambda x: x['filename']):
                filename = att['filename']
                att_id = att['id']
                # Use sanitized filename for the URL
                url_filename = sanitize_filename(filename)
                dest_path = os.path.join(output_dir, "attachments", page_id, att_id, url_filename)
                
                if copy_attachment(filename, page_id, dest_path, att_id):
                    attachment_links.append(f"- [{filename}](/attachments/{page_id}/{att_id}/{url_filename})")
                else:
                    attachment_links.append(f"- {filename} (not found)")
            
            attachment_links.append("{.links-list}")
            return '\n'.join(attachment_links)
        else:
            return "## Attachments\n\n_No attachments found_"
    
    # Pattern to match attachments macro
    attachments_pattern = r'<ac:structured-macro[^>]*ac:name="attachments"[^>]*>.*?</ac:structured-macro>'
    html_content = re.sub(attachments_pattern, replace_attachments_macro, html_content, flags=re.DOTALL)
    
    return html_content

# Function to format links for Wiki.js
def format_links_for_wikijs(markdown_content):
    """Post-process markdown to add {.links-list} after link lists and ensure standalone links have hyphens"""
    lines = markdown_content.split('\n')
    processed_lines = []
    i = 0
    
    while i < len(lines):
        line = lines[i]
        
        # Check if this line is a link without a list marker
        link_pattern = r'^\[.+\]\(.+\)$'
        if re.match(link_pattern, line.strip()) and not line.strip().startswith('-') and not line.strip().startswith('*') and not re.match(r'^\d+\.', line.strip()):
            # Check if this is a JIRA or external service link
            if re.search(r'\[JIRA [A-Z]+-\d+\]|MIRO|Miro', line.strip()):
                # Always format external service links as list items
                processed_lines.append('- ' + line.strip())
                processed_lines.append('{.links-list}')
                i += 1
                continue
                
            # Check if the next line is also a link to determine if it's a list
            is_list = False
            j = i + 1
            while j < len(lines) and lines[j].strip():
                if re.match(link_pattern, lines[j].strip()) or lines[j].strip().startswith('-') or lines[j].strip().startswith('*') or re.match(r'^\d+\.', lines[j].strip()):
                    is_list = True
                    break
                j += 1
            
            if is_list:
                # Process the entire link list
                list_lines = []
                while i < len(lines) and (re.match(link_pattern, lines[i].strip()) or lines[i].strip().startswith('-') or lines[i].strip().startswith('*') or re.match(r'^\d+\.', lines[i].strip())):
                    if re.match(link_pattern, lines[i].strip()) and not lines[i].strip().startswith('-'):
                        list_lines.append('- ' + lines[i].strip())
                    else:
                        list_lines.append(lines[i])
                    i += 1
                
                # Add all list lines
                processed_lines.extend(list_lines)
                # Add {.links-list} after the list
                processed_lines.append('{.links-list}')
                # Skip the increment at the end since we already moved i
                continue
            else:
                # Single link, add hyphen
                processed_lines.append('- ' + line.strip())
                processed_lines.append('{.links-list}')
                i += 1
                continue
        
        # Check if this is already a list of links (starts with -, *, or number)
        elif (line.strip().startswith('-') or line.strip().startswith('*') or re.match(r'^\d+\.', line.strip())) and '](' in line:
            # This is the start of a link list
            list_lines = []
            list_type = 'unordered' if line.strip().startswith('-') or line.strip().startswith('*') else 'ordered'
            
            # Collect all consecutive list items with links
            while i < len(lines):
                current_line = lines[i].strip()
                if not current_line:
                    # Empty line, end of list
                    break
                elif ((list_type == 'unordered' and (current_line.startswith('-') or current_line.startswith('*'))) or 
                      (list_type == 'ordered' and re.match(r'^\d+\.', current_line))) and '](' in current_line:
                    list_lines.append(lines[i])
                    i += 1
                else:
                    # Not a list item with a link
                    break
            
            if list_lines:
                # Add all list lines
                processed_lines.extend(list_lines)
                # Check if the next line is already {.links-list}
                if i < len(lines) and lines[i].strip() == '{.links-list}':
                    # It already has the class, just add it
                    processed_lines.append(lines[i])
                    i += 1
                else:
                    # Add {.links-list} after the list
                    processed_lines.append('{.links-list}')
                # Skip the increment at the end since we already moved i
                continue
        
        # Regular line, just add it
        processed_lines.append(line)
        i += 1
    
    return '\n'.join(processed_lines)

# Extract all BodyContent objects
print("\nExtracting body contents...")
import time

# Create a simple parser to extract BodyContent objects more reliably
def extract_body_contents(xml_content):
    bodies = []
    
    # Compile regex for better performance
    body_pattern = re.compile(r'<object class="BodyContent" package="com\.atlassian\.confluence\.core">')
    
    print(f"  Starting body content search in {len(xml_content):,} bytes of XML...")
    start_time = time.time()
    
    pos = 0
    found_count = 0
    while True:
        if found_count % 1000 == 0 and found_count > 0:
            elapsed = time.time() - start_time
            print(f"  Found {found_count} body contents so far... ({elapsed:.1f}s, position: {pos:,}/{len(xml_content):,} bytes)")
            # Force garbage collection periodically
            if found_count % 5000 == 0:
                gc.collect()
        
        match = body_pattern.search(xml_content, pos)
        if not match:
            break
            
        start = match.start()
        # Find the closing </object> tag
        end_pos = xml_content.find('</object>', start)
        if end_pos == -1:
            print(f"  WARNING: Found body content at position {start:,} but no closing tag")
            break
            
        body_xml = xml_content[start:end_pos + 9]  # +9 for '</object>'
        bodies.append(body_xml)
        found_count += 1
        
        pos = end_pos + 9
    
    elapsed = time.time() - start_time
    print(f"  Body content extraction complete: found {len(bodies)} objects in {elapsed:.1f}s")
    return bodies

bodies = extract_body_contents(content)

bodies_count = 0
extracted_count = 0
print(f"\nProcessing {len(bodies)} body contents...")
process_start = time.time()

for i, body in enumerate(bodies):
    if i % 100 == 0 and i > 0:
        elapsed = time.time() - process_start
        rate = i / elapsed
        remaining = (len(bodies) - i) / rate
        print(f"  Processing body content {i}/{len(bodies)} ({elapsed:.1f}s elapsed, ~{remaining:.0f}s remaining)")
    
    # Extract body ID
    body_id_match = re.search(r'<id name="id">(\d+)</id>', body)
    if not body_id_match:
        continue
    body_id = body_id_match.group(1)
    
    # Extract body content - handle the nested CDATA properly
    # The body content is wrapped in CDATA, but we need the raw content
    # For very large bodies, use a more efficient approach
    body_start = body.find('<property name="body"><![CDATA[')
    if body_start == -1:
        continue
    body_start += len('<property name="body"><![CDATA[')
    
    body_end = body.rfind(']]></property>')
    if body_end == -1:
        continue
    
    body_content = body[body_start:body_end]
    
    # In the XML export, nested CDATA sections have ]] escaped as ]]]]><![CDATA[>
    # We need to unescape these
    body_content = body_content.replace(']]]]><![CDATA[>', ']]')
    
    bodies_count += 1
    
    # Check if we have page info for this body
    if body_id in page_info:
        info = page_info[body_id]
        page_id = info['page_id']
        page_title = info['title']
        filename = info['filename']
        
        # Get space key for this page
        space_id = page_to_space.get(page_id)
        if space_id and space_id in space_info:
            space_key = space_info[space_id]['key']
        else:
            print(f"    WARNING: No space found for page '{page_title}' (ID: {page_id})")
            continue
            
        if extracted_count % 10 == 0 and extracted_count > 0:
            print(f"    Extracting page {extracted_count}: {page_title}")
        
        # Process the content
        try:
            body_content = fix_internal_links(body_content, space_key)
            body_content = convert_confluence_macros(body_content, page_id, space_key)
        except Exception as e:
            print(f"    ERROR processing page '{page_title}' (ID: {page_id}): {e}")
            continue
        
        # Create full HTML
        full_html = f"<h1>{page_title}</h1>\n\n{body_content}"
        
        # Convert to Markdown
        markdown_content = html_to_markdown(full_html)
        
        # Post-process markdown to format links properly
        markdown_content = format_links_for_wikijs(markdown_content)
        
        # Get additional metadata from latest_pages
        page_metadata = latest_pages.get(page_title, {})
        
        # Build metadata header
        metadata_lines = ["---"]
        metadata_lines.append(f"title: {page_title}")
        
        # Add author if available
        if page_metadata.get('creator'):
            metadata_lines.append(f"author: {page_metadata['creator']}")
        
        # Add description (you can customize this or extract from page content)
        # metadata_lines.append("description: ")
        
        # Add tags from labels if available
        if page_id in page_labels and page_labels[page_id]:
            # Filter out system labels that start with certain prefixes
            user_labels = [label for label in page_labels[page_id] 
                         if not label.startswith('blueprint-') 
                         and not label.startswith('com.atlassian.')]
            if user_labels:
                metadata_lines.append(f"tags: {user_labels}")
        
        # Add date - prefer creation date, fallback to last modified, then current date
        if page_metadata.get('creation_date'):
            # Extract just the date part (YYYY-MM-DD) from the timestamp
            date_part = page_metadata['creation_date'].split(' ')[0]
            metadata_lines.append(f"date: {date_part}")
        elif page_metadata.get('last_modified'):
            date_part = page_metadata['last_modified'].split(' ')[0]
            metadata_lines.append(f"date: {date_part}")
        else:
            metadata_lines.append("date: 2025-07-28")
        
        metadata_lines.append("---")
        metadata_lines.append("")
        
        metadata = '\n'.join(metadata_lines) + '\n'
        markdown_content = metadata + markdown_content
        
        # Add Parent Page block if this page has a parent
        if page_metadata.get('parent_id'):
            parent_id = page_metadata['parent_id']
            # Find the parent page info
            parent_info = None
            for parent_title, parent_data in latest_pages.items():
                if parent_data['page_id'] == parent_id:
                    parent_info = (parent_title, parent_data['page_id'])
                    break
            
            if parent_info:
                parent_title, parent_page_id = parent_info
                # Get the parent's space key
                parent_space_key = space_key  # Default to current space
                if parent_id in page_to_space and page_to_space[parent_id] in space_info:
                    parent_space_key = space_info[page_to_space[parent_id]]['key']
                
                # Add parent page block right after the title
                parent_block = f"\n> **Parent Page:** [{parent_title}](/wiki/spaces/{parent_space_key}/pages/{parent_page_id})\n"
                parent_block += "<!-- {blockquote:.is-info} -->\n"
                
                # Insert parent block after the title (first heading)
                lines = markdown_content.split('\n')
                insert_index = 0
                for i, line in enumerate(lines):
                    if line.startswith('# '):
                        insert_index = i + 1
                        break
                
                lines.insert(insert_index, parent_block)
                markdown_content = '\n'.join(lines)
        
        # Add Related Pages section if this page has children
        if page_id in page_children and page_children[page_id]:
            related_pages_section = "\n\n# Páginas Relacionadas\n\n"
            related_pages_section += "> "
            
            # Get child page details
            child_links = []
            for child_id in page_children[page_id]:
                # Find the child page info
                child_info = None
                for child_title, child_data in latest_pages.items():
                    if child_data['page_id'] == child_id:
                        child_info = (child_title, child_data['page_id'])
                        break
                
                if child_info:
                    child_title, child_page_id = child_info
                    # Get the child's space key
                    child_space_key = space_key  # Default to parent's space
                    if child_id in page_to_space and page_to_space[child_id] in space_info:
                        child_space_key = space_info[page_to_space[child_id]]['key']
                    
                    # Create relative link to child page
                    child_link = f"- [{child_title}](/wiki/spaces/{child_space_key}/pages/{child_page_id})"
                    child_links.append(child_link)
            
            if child_links:
                related_pages_section += "\n> ".join(child_links)
                related_pages_section += "\n> {.links-list}\n"
                related_pages_section += "<!-- {blockquote:.is-info} -->\n"
                markdown_content += related_pages_section
        
        # Create directory structure: wiki/spaces/{space_key}/pages/
        page_dir = os.path.join(temp_dir, "wiki", "spaces", space_key, "pages")
        os.makedirs(page_dir, exist_ok=True)
        
        # Save Markdown file with ID only as filename
        md_file = os.path.join(page_dir, f"{filename}.md")
        with open(md_file, 'w', encoding='utf-8') as f:
            f.write(markdown_content)
        
        print(f"Extracted: {page_title} -> /wiki/spaces/{space_key}/pages/{filename}.md")
        extracted_count += 1

# Process pages without body content
print("\nProcessing pages without body content...")
pages_without_body = 0
for page_title, page_data in latest_pages.items():
    page_id = page_data['page_id']
    
    # Check if this page was already processed (has body content)
    already_processed = False
    for body_id, info in page_info.items():
        if info['page_id'] == page_id:
            already_processed = True
            break
    
    if not already_processed:
        # Get space key for this page
        space_id = page_to_space.get(page_id)
        if space_id and space_id in space_info:
            space_key = space_info[space_id]['key']
        else:
            continue
        
        # Create minimal markdown content for pages without body
        markdown_content = f"# {page_title}\n\n*This page has no content.*"
        
        # Build metadata header
        metadata_lines = ["---"]
        metadata_lines.append(f"title: {page_title}")
        
        # Add author if available
        if page_data.get('creator'):
            metadata_lines.append(f"author: {page_data['creator']}")
        
        # Add tags from labels if available
        if page_id in page_labels and page_labels[page_id]:
            user_labels = [label for label in page_labels[page_id] 
                         if not label.startswith('blueprint-') 
                         and not label.startswith('com.atlassian.')]
            if user_labels:
                metadata_lines.append(f"tags: {user_labels}")
        
        # Add date
        if page_data.get('creation_date'):
            date_part = page_data['creation_date'].split(' ')[0]
            metadata_lines.append(f"date: {date_part}")
        elif page_data.get('last_modified'):
            date_part = page_data['last_modified'].split(' ')[0]
            metadata_lines.append(f"date: {date_part}")
        else:
            metadata_lines.append("date: 2025-07-28")
        
        metadata_lines.append("---")
        metadata_lines.append("")
        
        metadata = '\n'.join(metadata_lines) + '\n'
        markdown_content = metadata + markdown_content
        
        # Add Parent Page block if this page has a parent
        if page_data.get('parent_id'):
            parent_id = page_data['parent_id']
            # Find the parent page info
            parent_info = None
            for parent_title, parent_data_inner in latest_pages.items():
                if parent_data_inner['page_id'] == parent_id:
                    parent_info = (parent_title, parent_data_inner['page_id'])
                    break
            
            if parent_info:
                parent_title, parent_page_id = parent_info
                # Get the parent's space key
                parent_space_id = page_to_space.get(parent_page_id)
                if parent_space_id and parent_space_id in space_info:
                    parent_space_key = space_info[parent_space_id]['key']
                else:
                    parent_space_key = space_key
                
                # Insert Parent Page block after metadata
                lines = markdown_content.split('\n')
                insert_pos = 0
                for i, line in enumerate(lines):
                    if line.strip() == '---' and i > 0:  # Found end of metadata
                        insert_pos = i + 1
                        break
                
                parent_block = [
                    "",
                    f"> **Parent Page:** [{parent_title}](/wiki/spaces/{parent_space_key}/pages/{parent_page_id})",
                    ""
                ]
                
                lines = lines[:insert_pos] + parent_block + lines[insert_pos:]
                markdown_content = '\n'.join(lines)
        
        # Add child pages section if this page has children
        children = [child for child in page_children.get(page_id, [])]
        if children:
            # Filter to only include latest versions
            valid_children = []
            for child_id in children:
                # Find the child page info
                for child_title, child_data in latest_pages.items():
                    if child_data['page_id'] == child_id:
                        valid_children.append((child_title, child_id))
                        break
            
            if valid_children:
                markdown_content += "\n\n# Related Pages\n\n"
                for child_title, child_id in valid_children:
                    # Get the child's space key
                    child_space_id = page_to_space.get(child_id)
                    if child_space_id and child_space_id in space_info:
                        child_space_key = space_info[child_space_id]['key']
                    else:
                        child_space_key = space_key
                    markdown_content += f"> - [{child_title}](/wiki/spaces/{child_space_key}/pages/{child_id})\n"
                markdown_content += "> {.links-list}\n"
        
        # Create directory structure
        page_dir = os.path.join(temp_dir, "wiki", "spaces", space_key, "pages")
        os.makedirs(page_dir, exist_ok=True)
        
        # Save Markdown file
        md_file = os.path.join(page_dir, f"{page_id}.md")
        with open(md_file, 'w', encoding='utf-8') as f:
            f.write(markdown_content)
        
        print(f"  Created placeholder for: {page_title} -> /wiki/spaces/{space_key}/pages/{page_id}.md")
        pages_without_body += 1

total_elapsed = time.time() - process_start
print(f"\nProcessing complete in {total_elapsed:.1f}s!")
print(f"Total pages found: {pages_count}")
print(f"Total body contents found: {bodies_count}")
print(f"Successfully extracted with content: {extracted_count}")
print(f"Created placeholders for pages without content: {pages_without_body}")
print(f"Total pages created: {extracted_count + pages_without_body}")
if skip_attachments:
    print("Note: Attachment file copying was skipped")
EOF

# Move all files from temp to output, preserving directory structure
echo -e "\nMoving extracted files to output directory..."
if [ -d "$TEMP_DIR/wiki" ]; then
    # Create output directory structure
    mkdir -p "$OUTPUT_DIR"
    # Copy the entire wiki directory (use rsync or cp -r to merge)
    if [ -d "$OUTPUT_DIR/wiki" ]; then
        # Merge with existing directory
        cp -r "$TEMP_DIR/wiki/"* "$OUTPUT_DIR/wiki/" 2>/dev/null || true
    else
        # Move the entire wiki directory
        mv "$TEMP_DIR/wiki" "$OUTPUT_DIR/"
    fi
fi

# Count the extracted files
EXTRACTED_COUNT=$(find "$OUTPUT_DIR" -name "*.md" 2>/dev/null | wc -l)
echo "Complete! Extracted $EXTRACTED_COUNT pages to $OUTPUT_DIR/"

# Show directory structure
echo -e "\nDirectory structure created:"
find "$OUTPUT_DIR/wiki/spaces" -type d -name "pages" | head -5
echo "..."

if [ "$SKIP_ATTACHMENTS" = false ]; then
    ATTACHMENT_COUNT=$(find "$OUTPUT_DIR/wiki/spaces" -name "attachments" -type d 2>/dev/null | wc -l)
    echo "Created $ATTACHMENT_COUNT attachment directories"
fi