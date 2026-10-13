import GuavaUI
import GalleryContent

let launch = ShowcaseLaunch(arguments: CommandLine.arguments)
try Application.run(config: launch.configuration, checkpoint: launch.checkpoint) {
    launch.root
}
