#!/bin/bash

set -e

# Source utilities
source "$(dirname "$0")/utils.sh"

# Get project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_ROOT/.env"

# Check if speech services are in COMPOSE_PROFILES
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Check if any speech profile is active
if [[ "$COMPOSE_PROFILES" == *"speech"* ]] || [[ "$COMPOSE_PROFILES" == *"speech-cpu"* ]] || [[ "$COMPOSE_PROFILES" == *"speech-gpu"* ]]; then
    log_info "Speech services selected - Setting up Russian TTS voice (Irina)..."
    
    cd "$PROJECT_ROOT"
    
    # Create directories if they don't exist
    # Use mkdir -p which doesn't fail if directory exists
    if ! mkdir -p openedai-voices openedai-config 2>/dev/null; then
        log_warning "Could not create directories (permission issue)"
        log_info "Attempting with sudo..."
        sudo mkdir -p openedai-voices openedai-config
        # Set ownership to current user
        sudo chown -R $USER:$USER openedai-voices openedai-config
    fi
    
    # Russian Voice Setup (Irina - High Quality, Male)
    VOICE_FILE="openedai-voices/ru_RU-irina-medium.onnx"
    CONFIG_FILE="openedai-voices/ru_RU-irina-medium.onnx.json"
    
    if [ ! -f "$VOICE_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        log_info "Downloading Russian voice model (Irina - Medium Quality)..."
        log_info "This is a ~40MB download and may take a moment..."
        
        # Download voice model with proper error handling
        if ! wget -q --show-progress -O "$VOICE_FILE" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx" 2>&1; then
            
            # If permission denied, try with sudo
            if [ $? -eq 1 ] && [[ "$(ls -ld openedai-voices 2>/dev/null)" != d*$USER* ]]; then
                log_info "Retrying download with proper permissions..."
                sudo wget -q --show-progress -O "$VOICE_FILE" \
                    "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx" || {
                    log_error "Failed to download Russian voice model"
                    log_warning "Speech services will use default English voices"
                    log_info "Manual download: bash ./scripts/04b_setup_russian_voice.sh (run with sudo if needed)"
                    exit 0  # Non-critical error
                }
                sudo chown $USER:$USER "$VOICE_FILE"
            else
                log_error "Failed to download Russian voice model"
                log_warning "Speech services will use default English voices"
                log_info "Check internet connection and try again:"
                log_info "  sudo bash ./scripts/04b_setup_russian_voice.sh"
                exit 0  # Non-critical error
            fi
        fi
        
        # Download voice config
        if ! wget -q -O "$CONFIG_FILE" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/irina/medium/ru_RU-irina-medium.onnx.json" 2>/dev/null; then
            log_warning "Failed to download voice config, but model is available"
        fi
        
        log_success "Russian voice model downloaded successfully!"
        log_info "Voice file: $(du -h $VOICE_FILE | cut -f1)"
    else
        log_info "Russian voice model already exists - skipping download"
    fi
    
    # Create voice_to_speaker.yaml configuration
    VOICE_CONFIG="openedai-config/voice_to_speaker.yaml"
    VOICE_TEMPLATE="$PROJECT_ROOT/templates/voice_to_speaker.yaml"
    
    if [ ! -f "$VOICE_CONFIG" ]; then
        log_info "Creating voice configuration with Russian support..."
        
        # Use template file if available, otherwise create inline
        if [ -f "$VOICE_TEMPLATE" ]; then
            cp "$VOICE_TEMPLATE" "$VOICE_CONFIG"
            log_success "Voice configuration created from template!"
        else
            log_warning "Template not found, creating basic configuration..."
            # Fallback: create minimal config
            cat > "$VOICE_CONFIG" << 'EOFCONFIG'
tts-1:
  alloy:
    model: voices/en_US-libritts_r-medium.onnx
    speaker: 79
  irina:
    model: voices/ru_RU-irina-medium.onnx
    speaker: # default speaker
EOFCONFIG
        fi
        
        log_success "Voice configuration created with Russian support!"
        log_info "Available voices:"
        log_info "  - English: alloy, echo, fable, onyx, nova, shimmer"
        log_info "  - Russian: irina (native Russian pronunciation)"
    else
        log_info "Voice configuration already exists"
        
        # Check if irina is configured and in correct position
        if ! grep -q "irina:" "$VOICE_CONFIG"; then
            log_info "Adding irina voice to existing configuration..."
            cp "$VOICE_CONFIG" "${VOICE_CONFIG}.bak" 2>/dev/null || true
            
            # Insert irina before tts-1-hd section (correct position)
            if grep -q "^tts-1-hd:" "$VOICE_CONFIG"; then
                # Use sed to insert before tts-1-hd
                sudo sed -i '/^tts-1-hd:/i\  # Russian Voice - Irina (Male, Medium Quality)\n  irina:\n    model: voices/ru_RU-irina-medium.onnx\n    speaker: # default speaker\n' "$VOICE_CONFIG"
                log_success "Added irina voice to configuration!"
            else
                log_warning "Could not add irina voice automatically"
                log_info "Use template: cp templates/voice_to_speaker.yaml openedai-config/"
            fi
        else
            log_success "Irina voice already configured!"
        fi
    fi
    
    # Detect which speech service variant is running
    SPEECH_SERVICE=""
    if [[ "$COMPOSE_PROFILES" == *"speech-gpu"* ]]; then
        SPEECH_SERVICE="openedai-speech-gpu"
    elif [[ "$COMPOSE_PROFILES" == *"speech-cpu"* ]]; then
        SPEECH_SERVICE="openedai-speech-cpu"
    elif [[ "$COMPOSE_PROFILES" == *"speech"* ]]; then
        # Check which container is actually running
        if docker ps --format '{{.Names}}' | grep -q "openedai-speech"; then
            SPEECH_SERVICE="openedai-speech-cpu"  # Default/backward compatibility
        fi
    fi
    
    log_success "Russian TTS voice setup complete!"
    log_info ""
    log_info "📢 How to use the Russian voice:"
    log_info "  1. Restart OpenedAI Speech service:"
    if [ -n "$SPEECH_SERVICE" ]; then
        log_info "     sudo docker compose -p localai -f docker-compose.local.yml restart $SPEECH_SERVICE"
    else
        log_info "     sudo docker compose -p localai -f docker-compose.local.yml restart openedai-speech-cpu"
        log_info "     # or: openedai-speech-gpu (depending on your setup)"
    fi
    log_info "  2. Open Open Notebook: http://SERVER_IP:8100"
    log_info "  3. Go to: Settings → Models → Add Model"
    log_info "     - Provider: openai_compatible"
    log_info "     - Model Name: tts-1"
    log_info "     - Display Name: Local TTS"
    log_info "  4. In Podcast Episode Profile, set voice: 'irina'"
    log_info ""
    log_info "🎙️ The Irina voice will speak native Russian!"
    log_info "   Available voices: irina (RU), alloy/nova/echo (EN)"
    
    cd "$PROJECT_ROOT"
else
    log_info "Speech services not selected - skipping Russian voice setup"
    log_info "To enable later:"
    log_info "  1. Add 'speech-cpu' or 'speech-gpu' to COMPOSE_PROFILES in .env"
    log_info "  2. Run: bash ./scripts/04b_setup_russian_voice.sh"
    log_info "  3. Start services: docker compose -p localai -f docker-compose.local.yml up -d"
fi

exit 0
