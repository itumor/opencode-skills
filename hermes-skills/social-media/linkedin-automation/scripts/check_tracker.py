#!/usr/bin/env python3
"""Verify LinkedIn tracker state and preview next topic."""
import sys
sys.path.insert(0, '/Users/eramadan/.hermes/scripts')
from linkedin_postbot import load_rows, DEFAULT_STATE_FILE, posted_today, pick_next_topic, acquire_single_run_lock
from pathlib import Path

TRACKER = Path('/Users/eramadan/GitRepo/cncf_linkdin/cncf_linkedin_codex_kit/output/cncf_linkedin_tracker_tools_first.xlsx')

def main():
    print(f'Tracker: {TRACKER}')
    print(f'Tracker exists: {TRACKER.exists()}')
    
    rows = load_rows(TRACKER)
    print(f'Total topics: {len(rows)}')
    
    print(f'\nState file: {DEFAULT_STATE_FILE}')
    print(f'State exists: {DEFAULT_STATE_FILE.exists()}')
    
    is_posted = posted_today(DEFAULT_STATE_FILE)
    print(f'Posted today: {is_posted}')
    
    # Check lock
    lock_path = Path.home() / '.hermes' / 'cache' / 'linkedin-postbot.lock'
    print(f'Lock file: {lock_path}')
    print(f'Lock exists: {lock_path.exists()}')
    
    if not is_posted:
        try:
            row = pick_next_topic(rows, DEFAULT_STATE_FILE)
            print(f'\nNext topic: {row.tool}')
            print(f'Category: {row.category}')
            print(f'Description: {row.description}')
            print(f'Use case: {row.typical_use_case}')
            print(f'Alternatives: {row.common_alternatives}')
            print(f'Source URL: {row.source_url}')
        except SystemExit as e:
            print(f'Error: {e}')
    else:
        print('\nNo topic (already posted today)')

if __name__ == '__main__':
    main()
