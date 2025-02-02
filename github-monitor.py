#! /usr/bin/env python3


import os, json, time, datetime, random
import sseclient
import requests  

class GitHubEventMonitor:
    def __init__(self, owner, repo, token=None):
        self.owner = owner
        self.repo = repo
        self.token = token or os.environ.get('GITHUB_TOKEN')
        self.max_retries = 5
        self.base_delay = 1  # Start with 1 second delay
        self.max_delay = 60  # Max delay of 60 seconds
        
    def setup_sse_client(self):
        if not self.token:
            raise ValueError("GitHub token not provided")
            
        url = f'https://api.github.com/repos/{self.owner}/{self.repo}/events'
        headers = {
            'Accept': 'application/vnd.github.v3+json',
            'Authorization': f'token {self.token}'
        }
        return sseclient.SSEClient(url, headers=headers)
    
    def handle_event(self, event_data):
        data = json.loads(event_data)
        event_type = data.get('type')
        print(f"[{datetime.datetime.now()}] Received {event_type} event")
        
        # Add your event handling logic here
        
    def run(self):
        retry_count = 0
        delay = self.base_delay
        
        while True:
            try:
                print(f"Connecting to GitHub events stream for {self.owner}/{self.repo}...")
                client = self.setup_sse_client()
                
                # Reset retry count on successful connection
                retry_count = 0
                delay = self.base_delay
                
                for event in client.events():
                    self.handle_event(event.data)
                    
            except (requests.exceptions.ConnectionError, 
                    requests.exceptions.ChunkedEncodingError,
                    requests.exceptions.RequestException) as e:
                retry_count += 1
                
                if retry_count > self.max_retries:
                    print(f"Failed after {self.max_retries} retries. Resetting retry count.")
                    retry_count = 0
                    delay = self.base_delay
                else:
                    # Exponential backoff with jitter
                    jitter = random.uniform(0, 0.1 * delay)
                    delay = min(delay * 2 + jitter, self.max_delay)
                
                print(f"Connection error: {e}")
                print(f"Attempting reconnection in {delay:.1f} seconds... (Attempt {retry_count})")
                time.sleep(delay)
                
            except Exception as e:
                print(f"Unexpected error: {e}")
                print("Attempting reconnection in 5 seconds...")
                time.sleep(5)

if __name__ == '__main__':
    monitor = GitHubEventMonitor('dirkpetersen', 'spectater')
    monitor.run()

