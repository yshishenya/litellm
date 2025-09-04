#!/usr/bin/env python3
"""
Complete example for Veo video generation through LiteLLM proxy.

This script demonstrates how to:
1. Generate videos using Google's Veo model
2. Poll for completion status
3. Download the generated video file

Requirements:
- LiteLLM proxy running with Google AI Studio pass-through configured
- Google AI Studio API key with Veo access
"""

import json
import os
import time
import requests
from typing import Optional


class VeoVideoGenerator:
    """Complete Veo video generation client using LiteLLM proxy."""
    
    def __init__(self, base_url: str = "http://localhost:4000/gemini/v1beta", 
                 api_key: str = "sk-1234"):
        """
        Initialize the Veo video generator.
        
        Args:
            base_url: Base URL for the LiteLLM proxy with Gemini pass-through
            api_key: API key for LiteLLM proxy authentication
        """
        self.base_url = base_url
        self.api_key = api_key
        self.headers = {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json"
        }
    
    def generate_video(self, prompt: str) -> Optional[str]:
        """Initiate video generation with Veo.
        
        This function sends a request to the Veo API to generate a video based on the
        provided  text description in the `prompt`. It constructs the necessary payload
        and handles the  response, returning the operation name if the request is
        successful. In case of failure,  it logs the error details for debugging
        purposes.
        """
        print(f"🎬 Generating video with prompt: '{prompt}'")
        
        url = f"{self.base_url}/models/veo-3.0-generate-preview:predictLongRunning"
        payload = {
            "instances": [{
                "prompt": prompt
            }]
        }
        
        try:
            response = requests.post(url, headers=self.headers, json=payload)
            response.raise_for_status()
            
            data = response.json()
            operation_name = data.get("name")
            
            if operation_name:
                print(f"✅ Video generation started: {operation_name}")
                return operation_name
            else:
                print("❌ No operation name returned")
                print(f"Response: {json.dumps(data, indent=2)}")
                return None
                
        except requests.RequestException as e:
            print(f"❌ Failed to start video generation: {e}")
            if hasattr(e, 'response') and e.response is not None:
                try:
                    error_data = e.response.json()
                    print(f"Error details: {json.dumps(error_data, indent=2)}")
                except:
                    print(f"Error response: {e.response.text}")
            return None
    
    def wait_for_completion(self, operation_name: str, max_wait_time: int = 600) -> Optional[str]:
        """Polls the operation status until video generation is complete.
        
        This function monitors the status of a video generation operation by
        repeatedly sending requests to the specified operation URL. It checks  for
        errors in the response and determines if the operation is complete.  If
        successful, it extracts and returns the video URI. The polling  interval
        increases with each attempt, capped at 30 seconds, and the  function will time
        out after the specified max_wait_time.
        
        Args:
            operation_name: Name of the operation to monitor.
            max_wait_time: Maximum time to wait in seconds (default: 10 minutes).
        """
        print("⏳ Waiting for video generation to complete...")
        
        operation_url = f"{self.base_url}/{operation_name}"
        start_time = time.time()
        poll_interval = 10  # Start with 10 seconds
        
        while time.time() - start_time < max_wait_time:
            try:
                print(f"🔍 Polling status... ({int(time.time() - start_time)}s elapsed)")
                
                response = requests.get(operation_url, headers=self.headers)
                response.raise_for_status()
                
                data = response.json()
                
                # Check for errors
                if "error" in data:
                    print("❌ Error in video generation:")
                    print(json.dumps(data["error"], indent=2))
                    return None
                
                # Check if operation is complete
                is_done = data.get("done", False)
                
                if is_done:
                    print("🎉 Video generation complete!")
                    
                    try:
                        # Extract video URI from nested response
                        video_uri = data["response"]["generateVideoResponse"]["generatedSamples"][0]["video"]["uri"]
                        print(f"📹 Video URI: {video_uri}")
                        return video_uri
                    except KeyError as e:
                        print(f"❌ Could not extract video URI: {e}")
                        print("Full response:")
                        print(json.dumps(data, indent=2))
                        return None
                
                # Wait before next poll, with exponential backoff
                time.sleep(poll_interval)
                poll_interval = min(poll_interval * 1.2, 30)  # Cap at 30 seconds
                
            except requests.RequestException as e:
                print(f"❌ Error polling operation status: {e}")
                time.sleep(poll_interval)
        
        print(f"⏰ Timeout after {max_wait_time} seconds")
        return None
    
    def download_video(self, video_uri: str, output_filename: str = "generated_video.mp4") -> bool:
        """Download the generated video file.
        
        This function initiates the download of a video file from a specified URI,
        converting it to a LiteLLM proxy URI if necessary. It handles streaming
        downloads with automatic redirect management and provides progress updates
        during the download process. After downloading, it verifies the file's
        existence and size, ensuring that the download was successful.
        
        Args:
            video_uri (str): URI of the video to download (from Google's response).
            output_filename (str): Local filename to save the video.
        
        Returns:
            bool: True if download successful, False otherwise.
        """
        print(f"⬇️  Downloading video...")
        print(f"Original URI: {video_uri}")
        
        # Convert Google URI to LiteLLM proxy URI
        # Example: files/abc123 -> /gemini/v1beta/files/abc123:download?alt=media
        if video_uri.startswith("files/"):
            download_path = f"{video_uri}:download?alt=media"
        else:
            download_path = video_uri
            
        litellm_download_url = f"{self.base_url}/{download_path}"
        print(f"Download URL: {litellm_download_url}")
        
        try:
            # Download with streaming and redirect handling
            response = requests.get(
                litellm_download_url, 
                headers=self.headers, 
                stream=True,
                allow_redirects=True  # Handle redirects automatically
            )
            response.raise_for_status()
            
            # Save video file
            with open(output_filename, 'wb') as f:
                downloaded_size = 0
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        downloaded_size += len(chunk)
                        
                        # Progress indicator for large files
                        if downloaded_size % (1024 * 1024) == 0:  # Every MB
                            print(f"📦 Downloaded {downloaded_size / (1024*1024):.1f} MB...")
            
            # Verify file was created and has content
            if os.path.exists(output_filename):
                file_size = os.path.getsize(output_filename)
                if file_size > 0:
                    print(f"✅ Video downloaded successfully!")
                    print(f"📁 Saved as: {output_filename}")
                    print(f"📏 File size: {file_size / (1024*1024):.2f} MB")
                    return True
                else:
                    print("❌ Downloaded file is empty")
                    os.remove(output_filename)
                    return False
            else:
                print("❌ File was not created")
                return False
                
        except requests.RequestException as e:
            print(f"❌ Download failed: {e}")
            if hasattr(e, 'response') and e.response is not None:
                print(f"Status code: {e.response.status_code}")
                print(f"Response headers: {dict(e.response.headers)}")
            return False
    
    def generate_and_download(self, prompt: str, output_filename: str = None) -> bool:
        # Auto-generate filename if not provided
        """Complete workflow to generate a video and download it.
        
        This function handles the entire process of video generation based on a text
        description provided in the `prompt`. It first checks if an `output_filename`
        is given; if not, it auto-generates one using the prompt and the current
        timestamp.  The function then calls `generate_video` to create the video, waits
        for the  operation to complete using `wait_for_completion`, and finally
        downloads the  video using `download_video`. It returns a boolean indicating
        the success of  the operation.
        
        Args:
            prompt: Text description for video generation.
            output_filename: Output filename (auto-generated if None).
        """
        if output_filename is None:
            timestamp = int(time.time())
            safe_prompt = "".join(c for c in prompt[:30] if c.isalnum() or c in (' ', '-', '_')).rstrip()
            output_filename = f"veo_video_{safe_prompt.replace(' ', '_')}_{timestamp}.mp4"
        
        print("=" * 60)
        print("🎬 VEO VIDEO GENERATION WORKFLOW")
        print("=" * 60)
        
        # Step 1: Generate video
        operation_name = self.generate_video(prompt)
        if not operation_name:
            return False
        
        # Step 2: Wait for completion
        video_uri = self.wait_for_completion(operation_name)
        if not video_uri:
            return False
        
        # Step 3: Download video
        success = self.download_video(video_uri, output_filename)
        
        if success:
            print("=" * 60)
            print("🎉 SUCCESS! Video generation complete!")
            print(f"📁 Video saved as: {output_filename}")
            print("=" * 60)
        else:
            print("=" * 60)
            print("❌ FAILED! Video generation or download failed")
            print("=" * 60)
        
        return success


def main():
    
    # Configuration from environment or defaults
    """Starts the Veo Video Generation Example with configured settings."""
    base_url = os.getenv("LITELLM_BASE_URL", "http://localhost:4000/gemini/v1beta")
    api_key = os.getenv("LITELLM_API_KEY", "sk-1234")
    
    print("🚀 Starting Veo Video Generation Example")
    print(f"📡 Using LiteLLM proxy at: {base_url}")
    
    # Initialize generator
    generator = VeoVideoGenerator(base_url=base_url, api_key=api_key)
    
    # Example prompts - try different ones!
    example_prompts = [
        "A cat playing with a ball of yarn in a sunny garden",
        "Ocean waves crashing against rocky cliffs at sunset",
        "A bustling city street with people walking and cars passing by",
        "A peaceful forest with sunlight filtering through the trees"
    ]
    
    # Use first example or get from user
    prompt = example_prompts[0]
    print(f"🎬 Using prompt: '{prompt}'")
    
    # Generate and download video
    success = generator.generate_and_download(prompt)
    
    if success:
        print("\n✅ Example completed successfully!")
        print("💡 Try modifying the prompt in the script for different videos!")
    else:
        print("\n❌ Example failed!")
        print("🔧 Check your LiteLLM proxy configuration and Google AI Studio API key")
        
        # Troubleshooting tips
        print("\n🔍 Troubleshooting:")
        print("1. Ensure LiteLLM proxy is running with Google AI Studio pass-through")
        print("2. Verify your Google AI Studio API key has Veo access")
        print("3. Check that your prompt meets Veo's content guidelines")
        print("4. Review the LiteLLM proxy logs for detailed error information")


if __name__ == "__main__":
    main()
