#!/usr/bin/env python3

import os
import time
import datetime
import subprocess
import requests

class GitHubEventMonitor:
    def __init__(self, work_root):
        self.work_root = work_root
        self.token = os.environ.get('GITHUB_TOKEN')
        self.max_retries = 5
        self.base_delay = 1
        self.max_delay = 60
        self.monitored_repos = {}
        
    def discover_repos(self):
        """Find all GitHub repositories in work directory"""
        self.monitored_repos = {}
        for root, dirs, files in os.walk(self.work_root):
            if '.git' in dirs:
                rel_path = os.path.relpath(root, self.work_root)
                owner, repo = rel_path.split(os.sep)[-2:]
                self.monitored_repos[f"{owner}/{repo}"] = {
                    'path': root,
                    'etag': '',
                    'last_event': None
                }

    def check_repository(self, owner, repo):
        """Check for new events in a repository"""
        url = f'https://api.github.com/repos/{owner}/{repo}/events'
        headers = {
            'Accept': 'application/vnd.github.v3+json',
            'Authorization': f'token {self.token}',
            'If-None-Match': self.monitored_repos[f"{owner}/{repo}"]['etag']
        }
        
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 304:
            return []
        response.raise_for_status()
        
        self.monitored_repos[f"{owner}/{repo}"]['etag'] = response.headers.get('ETag', '')
        return response.json()

    def handle_update(self, repo_info):
        """Process updates for a repository"""
        print(f"Updating repository: {repo_info['path']}")
        
        # Run git pull
        subprocess.run(['git', 'pull'], cwd=repo_info['path'], check=True)
        
        # Update dependencies
        venv_path = os.path.join(repo_info['path'], '.venv')
        req_file = os.path.join(repo_info['path'], 'requirements.txt')
        if os.path.exists(req_file):
            subprocess.run([os.path.join(venv_path, 'bin', 'pip'), 
                          'install', '-U', '-r', req_file], check=True)
            
        # Restart service (service name is based on directory name)
        service_name = os.path.basename(repo_info['path'])
        subprocess.run(['systemctl', '--user', 'restart', service_name], check=True)

    def run(self):
        while True:
            self.discover_repos()
            
            for repo_id in self.monitored_repos.copy():
                owner, repo = repo_id.split('/')
                try:
                    events = self.check_repository(owner, repo)
                    for event in events:
                        if event['type'] in ['Push', 'Merge']:
                            print(f"Detected update event in {repo_id}")
                            self.handle_update(self.monitored_repos[repo_id])
                            break  # Only process first relevant event
                except Exception as e:
                    print(f"Error checking {repo_id}: {str(e)}")
            
            time.sleep(60)  # Check every minute

if __name__ == '__main__':
    work_root = os.path.join(os.path.expanduser("~/vekku"), ".work", "github.com")
    monitor = GitHubEventMonitor(work_root)
    monitor.run()

