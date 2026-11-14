// Generated from documentation fetched on 2026-11-14; see plans/syrup/2026-11-14/provider-shape-corpus.md.
// Each case keeps its source and a phrase from the page, so it can be found again. `note` says what,
// if anything, was changed to put the documented example on the wire.

enum ProviderCorpus {
    static let retrieved = "2026-11-14"

    static let streams: [ProviderStreamCase] = [
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"first chunk: role with empty content"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"content delta"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}]}"#,
            ],
            text: #"Hello"#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"SSE comment-style line inside the documented example"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"The page's placeholder for omitted chunks, in SSE comment form; the API is not described as sending it."#,
            lines: [
                #": Intermediate chat completion chunks omitted."#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"final chunk: empty delta, finish_reason stop"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}"#,
            ],
            text: #""#, progress: 0, end: .stop
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"[DONE] terminator"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"As printed."#,
            lines: [
                #"data: [DONE]"#,
            ],
            text: #""#, progress: 0, end: .done
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"whole documented stream, with blank-line event separators"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create.md"#,
            nearby: #"### Streaming ... #### Response example"#,
            note: #"As printed, blank lines included."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}"#,
                #""#,
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}]}"#,
                #""#,
                #": Intermediate chat completion chunks omitted."#,
                #""#,
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra", "system_fingerprint": "fp_44709d6fcb", "choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}"#,
                #""#,
                #"data: [DONE]"#,
            ],
            text: #"Hello"#, progress: 1, end: .stopDone
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"chunk object carrying an obfuscation field"#,
            source: #"https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events.md"#,
            nearby: #"Represents a streamed chunk of a chat completion response returned by the model ... ### Example"#,
            note: #"Printed as a bare JSON object; `data: ` added."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-6-astra","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],"obfuscation":"r4N7vQ2m"}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenAI"#, label: #"tool-call deltas: successive values of delta.tool_calls"#,
            source: #"https://developers.openai.com/api/docs/guides/function-calling?api-mode=chat"#,
            nearby: #"Output delta.tool_calls"#,
            note: #"The page prints successive values of `delta.tool_calls`; each is wrapped here as `{"choices":[{"delta":{"tool_calls":VALUE}}]}`."#,
            lines: [
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_DdmO9pD3xa9XTPNJ32zg2hcA","function":{"arguments":"","name":"get_weather"},"type":"function"}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"{\"","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"location","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"\":\"","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"Paris","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":",","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":" France","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"arguments":"\"}","name":null},"type":null}]}}]}"#,
                #"data: {"choices":[{"delta":{"tool_calls":null}}]}"#,
            ],
            text: #""#, progress: 8, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"SSE comment keepalive"#,
            source: #"https://openrouter.ai/docs/api_reference/streaming.md"#,
            nearby: #"OpenRouter occasionally sends comments to prevent connection timeouts. These comments look like:"#,
            note: #"As printed."#,
            lines: [
                #": OPENROUTER PROCESSING"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"mid-stream error chunk, provider disconnect (HTTP 200 already sent)"#,
            source: #"https://openrouter.ai/docs/api_reference/streaming.md"#,
            nearby: #"The stream ends with a chunk that carries a top-level `error`:"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"cmpl-abc123","object":"chat.completion.chunk","created":1234567890,"model":"openai/gpt-4o","provider":"openai","error":{"code":502,"message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#,
            ],
            text: #""#, progress: 0, end: .providerError
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"mid-stream error chunk with error.metadata.error_type (HTTP 200 already sent)"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"Example SSE data:"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"gen-abc123","object":"chat.completion.chunk","created":1234567890,"model":"openai/gpt-4o","provider":"OpenAI","error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#,
            ],
            text: #""#, progress: 0, end: .providerError
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"mid-stream rate limit chunk"#,
            source: #"https://openrouter.ai/docs/api_reference/limits.md"#,
            nearby: #"If a rate limit is hit after streaming has started, the error arrives as an SSE event with `finish_reason: "error"`"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"cmpl-abc123","object":"chat.completion.chunk","created":1234567890,"model":"openai/gpt-4o","provider":"openai","error":{"code":429,"message":"Rate limit exceeded"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#,
            ],
            text: #""#, progress: 0, end: .providerError
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"reasoning_details delta chunk"#,
            source: #"https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md"#,
            nearby: #"In streaming responses, `reasoning_details` appears in delta chunks as the reasoning is generated:"#,
            note: #"Printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"Let me think about this step by step...","signature":null,"id":"reasoning-text-1","format":"anthropic-claude-v1","index":0}]}}]}"#,
            ],
            text: #""#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"debug chunk with empty choices array"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"OpenRouter sends a debug chunk as the **first chunk** in the streaming response. This chunk has an empty `choices` array"#,
            note: #"Printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"gen-xxxxx","provider":"Anthropic","model":"anthropic/claude-haiku-5.5","object":"chat.completion.chunk","created":1234567890,"choices":[],"debug":{"echo_upstream_body":{"system":[{"type":"text","text":"You are a helpful assistant."}],"messages":[{"role":"user","content":"Hello!"}],"model":"claude-haiku-5-5","stream":true,"max_tokens":65536}}}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"usage object on a chunk (fragment)"#,
            source: #"https://openrouter.ai/docs/cookbook/administration/usage-accounting.md"#,
            nearby: #"Every response includes a `usage` object with detailed token information. ... ### Chat Completions"#,
            note: #"An abridged chunk printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"object":"chat.completion.chunk","usage":{"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":0},"cost":0.95,"cost_details":{"upstream_inference_cost":19},"prompt_tokens":194,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":100,"audio_tokens":0},"total_tokens":196}}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"in-stream error event with empty choices, followed by an empty-delta chunk with usage"#,
            source: #"https://openrouter.ai/docs/guides/features/plugins/alignment.md"#,
            nearby: #"With `stream: true`, the same request yields two events, the error event and a chunk with an empty delta and `usage`, and the stream closes:"#,
            note: #"Each event printed as pretty JSON after one `data:`; each compacted onto one line."#,
            lines: [
                #"data: {"id":"gen-1790884916-d0qFpUtt9VekhqYFOsCP","object":"chat.completion.chunk","choices":[],"error":{"code":403,"message":"Alignment plugin: the reply broke these rules: rules[0]: \"Do not say a refund is issued or approved.\"","metadata":{"error_type":"permission_denied","alignment":{"calls":[{"call":1,"outcome":"blocked","rules":[{"applicable":true,"probability":0.97,"broken":true},{"applicable":true,"probability":0.02,"broken":false}]}],"rejected":{"role":"assistant","content":"Yes, you will receive a full refund for the damaged mug.","refusal":null}}}}}"#,
                #"data: {"id":"gen-1790884916-d0qFpUtt9VekhqYFOsCP","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"","role":"assistant"},"finish_reason":null,"native_finish_reason":null}],"usage":{"prompt_tokens":74,"completion_tokens":14,"total_tokens":88}}"#,
            ],
            text: #""#, progress: 0, end: .providerError
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"OpenAPI example chunk: role and content delta"#,
            source: #"https://openrouter.ai/openapi.json"#,
            nearby: #"components.schemas.ChatStreamChunk.example"#,
            note: #"An OpenAPI example value; `data: ` added."#,
            lines: [
                #"data: {"choices":[{"delta":{"content":"Hello","role":"assistant"},"finish_reason":null,"index":0}],"created":1677652288,"id":"chatcmpl-123","model":"openai/gpt-4","object":"chat.completion.chunk"}"#,
            ],
            text: #"Hello"#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"OpenRouter"#, label: #"OpenAPI example tool-call delta element (not a full chunk)"#,
            source: #"https://openrouter.ai/openapi.json"#,
            nearby: #"components.schemas.ChatStreamToolCall.example"#,
            note: #"An OpenAPI example of one `delta.tool_calls` element; wrapped as `{"choices":[{"delta":{"tool_calls":[ELEMENT]}}]}`."#,
            lines: [
                #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"location\": \"...\"}","name":"get_weather"},"id":"call_abc123","index":0,"type":"function"}]}}]}"#,
            ],
            text: #""#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"Mistral"#, label: #"first chunk: role with empty content"#,
            source: #"https://docs.mistral.ai/inference/conversations/chat-completion.md"#,
            nearby: #"curl request with "stream": true, then <TabItem value="output" label="output">"#,
            note: #"Printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"Mistral"#, label: #"content delta"#,
            source: #"https://docs.mistral.ai/inference/conversations/chat-completion.md"#,
            nearby: #"curl request with "stream": true, then <TabItem value="output" label="output">"#,
            note: #"Printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"3"},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
            ],
            text: #"3"#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"Mistral"#, label: #"final chunk: content, finish_reason stop, usage"#,
            source: #"https://docs.mistral.ai/inference/conversations/chat-completion.md"#,
            nearby: #"curl request with "stream": true, then <TabItem value="output" label="output">"#,
            note: #"Printed pretty and without `data: `; compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"00"},"finish_reason":"stop"}],"object":"chat.completion.chunk","created":1764258570,"usage":{"prompt_tokens":19,"completion_tokens":7,"total_tokens":26}}"#,
            ],
            text: #"00"#, progress: 1, end: .stop
        ),
        ProviderStreamCase(
            provider: #"Mistral"#, label: #"whole documented output: five chunk objects back to back"#,
            source: #"https://docs.mistral.ai/inference/conversations/chat-completion.md"#,
            nearby: #"curl request with "stream": true, then <TabItem value="output" label="output">"#,
            note: #"Five chunks printed pretty, back to back, without `data: `; each compacted onto its own `data:` line."#,
            lines: [
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"3"},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"84"},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"4"},"finish_reason":null}],"object":"chat.completion.chunk","created":1764258570,"usage":null}"#,
                #"data: {"id":"59060ef9339a4112b2c9e57e3ee6199d","model":"mistral-large-latest","choices":[{"index":0,"delta":{"content":"00"},"finish_reason":"stop"}],"object":"chat.completion.chunk","created":1764258570,"usage":{"prompt_tokens":19,"completion_tokens":7,"total_tokens":26}}"#,
            ],
            text: #"384400"#, progress: 4, end: .stop
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"first chunk: role with empty content"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],"usage":null}"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"content delta"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
            ],
            text: #"Hello"#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"content delta containing an emoji"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" 👋"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
            ],
            text: #" 👋"#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"final chunk: empty content, finish_reason stop, usage"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed."#,
            lines: [
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":""},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":11,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":0},"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}"#,
            ],
            text: #""#, progress: 0, end: .stop
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"[DONE] terminator"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed."#,
            lines: [
                #"data: [DONE]"#,
            ],
            text: #""#, progress: 0, end: .done
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"whole documented stream, with blank-line event separators"#,
            source: #"https://api-docs.deepseek.com/api/create-chat-completion.md"#,
            nearby: #"### 200 (Streaming) ... OK, returns a streamed sequence of `chat completion chunk` objects ... **Example**"#,
            note: #"As printed, blank lines included."#,
            lines: [
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":"!"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" 👋"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" How"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" can"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" I"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" help"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" you"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":" today"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":"?"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
                #""#,
                #"data: {"id":"071f229d-daa0-4557-a580-106a22e8df73","object":"chat.completion.chunk","created":1793084907,"model":"deepseek-flash","system_fingerprint":"e72d3c7f663d3e1383b00b3884cb4501","choices":[{"index":0,"delta":{"content":""},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":11,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":0},"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}"#,
                #""#,
                #"data: [DONE]"#,
            ],
            text: #"Hello! 👋 How can I help you today?"#, progress: 10, end: .stopDone
        ),
        ProviderStreamCase(
            provider: #"DeepSeek"#, label: #"SSE comment keepalive"#,
            source: #"https://api-docs.deepseek.com/quick_start/rate_limit.md"#,
            nearby: #"Streaming requests: Continuously return SSE keep-alive comments"#,
            note: #"Quoted in a sentence on the page."#,
            lines: [
                #": keep-alive"#,
            ],
            text: #""#, progress: 0, end: .open
        ),
        ProviderStreamCase(
            provider: #"vLLM"#, label: #"reasoning delta in delta.reasoning (latest docs)"#,
            source: #"https://docs.vllm.ai/en/latest/features/reasoning_outputs/"#,
            nearby: #"The `reasoning` field is available in the `delta` field in chat completion response chunks."#,
            note: #"Printed pretty, without `data: `, and with a trailing comma that makes it invalid JSON; the comma is removed and the chunk compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"is"},"logprobs":null,"finish_reason":null}]}"#,
            ],
            text: #""#, progress: 1, end: .open
        ),
        ProviderStreamCase(
            provider: #"vLLM"#, label: #"reasoning delta in delta.reasoning_content (v0.10.2 docs)"#,
            source: #"https://docs.vllm.ai/en/v0.10.2/features/reasoning_outputs.html"#,
            nearby: #"The `reasoning_content` field is available in the `delta` field in chat completion response chunks."#,
            note: #"Printed pretty, without `data: `, and with a trailing comma that makes it invalid JSON; the comma is removed and the chunk compacted onto one `data:` line."#,
            lines: [
                #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"is"},"logprobs":null,"finish_reason":null}]}"#,
            ],
            text: #""#, progress: 1, end: .open
        ),
    ]

    static let errors: [ProviderErrorCase] = [
        ProviderErrorCase(
            provider: #"OpenAI"#, label: #"error envelope with type, code, message, param (Agents API files guide, not Chat Completions)"#,
            source: #"https://developers.openai.com/api/docs/guides/agents-api/environments/files.md"#,
            nearby: #"For HTTP 400, use `error.param` and `error.message` to identify the input to correct. For example, a destination outside `/workspace` returns:"#,
            status: 400, body: #"{"error":{"type":"invalid_request_error","code":"invalid_request_error","message":"path must be an absolute POSIX path inside /workspace","param":"path"}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"OpenAI"#, label: #"rate limit error envelope with null param (Agents API errors guide, not Chat Completions)"#,
            source: #"https://developers.openai.com/api/docs/guides/agents-api/errors.md"#,
            nearby: #"Session creation and file attachment requests can return HTTP 429 with `files_api_rate_limit_exceeded`."#,
            status: 429, body: #"{"error":{"type":"rate_limit_error","code":"files_api_rate_limit_exceeded","message":"The Files API rate limit for your user has been exceeded. Reduce the rate of requests that access files, then try again.","param":null}}"#,
            expected: .rateLimited
        ),
        ProviderErrorCase(
            provider: #"OpenRouter"#, label: #"error before the response is committed"#,
            source: #"https://openrouter.ai/docs/api_reference/streaming.md"#,
            nearby: #"you get a standard JSON error response with the appropriate HTTP status code"#,
            status: 400, body: #"{"error":{"code":400,"message":"Invalid model specified"}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"OpenRouter"#, label: #"provider error body with metadata.error_type and provider_code"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"For Chat Completions, a provider error that interrupts generation carries `error_type` inside `error.metadata`:"#,
            status: nil, body: #"{"error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded","provider_code":"rate_limited"}}}"#,
            expected: nil
        ),
        ProviderErrorCase(
            provider: #"OpenRouter"#, label: #"budget limit rejection with metadata"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"the request is rejected with a `403` before it reaches a provider"#,
            status: 403, body: #"{"error":{"code":403,"message":"Budget limit exceeded (weekly limit). Contact your org admin. $52.00 of $50.00 used; resets 2026-10-12T00:00:00.000Z.","metadata":{"limit_source":"openrouter_guardrail_budget","remedy_hint":"Wait for the budget window to reset (see metadata.resets_at), or ask your org admin to raise the guardrail budget.","scope":"workspace_default_member","limit_usd":50,"spend_usd":52,"resets_at":"2026-10-12T00:00:00.000Z"}}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"OpenRouter"#, label: #"guardrail block"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"the response is a `403` with a message describing the block reason"#,
            status: 403, body: #"{"error":{"code":403,"message":"Request blocked: prompt injection patterns detected","metadata":{"patterns":["ignore all previous instructions"]}}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"OpenRouter"#, label: #"non-streaming response with error embedded in the choice"#,
            source: #"https://openrouter.ai/docs/api_reference/errors-and-debugging.md"#,
            nearby: #"For non-streaming requests where a provider error occurs, the error is embedded in the final response alongside any partial content:"#,
            status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"partial output..."},"finish_reason":"error","error":{"code":502,"message":"Provider disconnected mid-stream","metadata":{"error_type":"provider_unavailable"}}}]}"#,
            expected: .providerError
        ),
        ProviderErrorCase(
            provider: #"Mistral"#, label: #"error response format"#,
            source: #"https://docs.mistral.ai/resources/error-glossary.md"#,
            nearby: #"All errors return a JSON body with this structure:"#,
            status: nil, body: #"{"object":"error","message":"A human-readable description of the error.","type":"invalid_request_error","param":"model","code":"unknown_model"}"#,
            expected: nil
        ),
        ProviderErrorCase(
            provider: #"Groq"#, label: #"error object structure"#,
            source: #"https://console.groq.com/docs/errors.md"#,
            nearby: #"The error object follows a specific structure, providing a clear and actionable message alongside an error type classification:"#,
            status: nil, body: #"{"error":{"message":"String - description of the specific error","type":"invalid_request_error"}}"#,
            expected: nil
        ),
        ProviderErrorCase(
            provider: #"Groq"#, label: #"invalid tool call generated, with failed_generation"#,
            source: #"https://console.groq.com/docs/tool-use/local-tool-calling.md"#,
            nearby: #"Groq API returns a **400 error** with an explanation in the `"failed_generation"` field of the response body. **Example error response:**"#,
            status: 400, body: #"{"error":{"message":"Invalid tool call generated","type":"invalid_request_error","failed_generation":{"reason":"Tool call arguments are not valid JSON","tool_call_id":"call_abc123","attempted_arguments":"{'location': 'New York'}"}}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"Groq"#, label: #"model blocked at the organization level"#,
            source: #"https://console.groq.com/docs/model-permissions.md"#,
            nearby: #"Requests to restricted models return a 403 error ... When a model is blocked at the organization level:"#,
            status: 403, body: #"{"error":{"message":"The model `openai/gpt-oss-120b` is blocked at the organization level. Please have the org admin enable this model in the org settings at https://console.groq.com/settings/limits","type":"permissions_error","code":"model_permission_blocked_org"}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"Groq"#, label: #"model blocked at the project level"#,
            source: #"https://console.groq.com/docs/model-permissions.md"#,
            nearby: #"Requests to restricted models return a 403 error ... When a model is blocked at the project level:"#,
            status: 403, body: #"{"error":{"message":"The model `openai/gpt-oss-120b` is blocked at the project level. Please have a project admin enable this model in the project settings at https://console.groq.com/settings/project/limits","type":"permissions_error","code":"model_permission_blocked_project"}}"#,
            expected: .httpStatus
        ),
        ProviderErrorCase(
            provider: #"Ollama"#, label: #"error message body (error is a plain string)"#,
            source: #"https://docs.ollama.com/api/errors.md"#,
            nearby: #"Errors are returned in the `application/json` format with the following structure, with the error message in the `error` property:"#,
            status: nil, body: #"{"error":"the model failed to generate a response"}"#,
            expected: nil
        ),
    ]

    /// Documented examples left out, and why.
    static let excluded: [(provider: String, label: String, reason: String)] = [
        (#"OpenRouter"#, #"last content chunk, usage chunk, [DONE] (abridged by the docs with '...')"#, #"abridged by the page with a literal `...`, so not JSON"#),
        (#"LM Studio"#, #"tool-call deltas as Python SDK objects (not wire JSON)"#, #"OpenAI Python SDK printouts, not wire JSON"#),
        (#"Ollama"#, #"error mid-stream in the native NDJSON API (not SSE)"#, #"Ollama's native NDJSON API, not SSE"#),
    ]
}
