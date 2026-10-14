private import CSDL3
import GuavaLogging

func installSDLLogging() {
    SDL_SetLogOutputFunction({ _, category, priority, message in
        let level: Logger.Level
        switch priority {
        case SDL_LOG_PRIORITY_TRACE, SDL_LOG_PRIORITY_VERBOSE: level = .trace
        case SDL_LOG_PRIORITY_DEBUG: level = .debug
        case SDL_LOG_PRIORITY_WARN: level = .warning
        case SDL_LOG_PRIORITY_ERROR: level = .error
        case SDL_LOG_PRIORITY_CRITICAL: level = .critical
        default: level = .info
        }
        LogSystem.logger("com.guava.engine.sdl").log(level: level,
            "\(message.map(String.init(cString:)) ?? "")", metadata: ["category": "\(category)"], source: "SDL")
    }, nil)
}
