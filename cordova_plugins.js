
  cordova.define('cordova/plugin_list', function(require, exports, module) {
    module.exports = [
      {
          "id": "cordova-plugin-exoplayer.ExoPlayer",
          "file": "plugins/cordova-plugin-exoplayer/www/exoplayer.js",
          "pluginId": "cordova-plugin-exoplayer",
        "clobbers": [
          "ExoPlayer"
        ]
        }
    ];
    module.exports.metadata =
    // TOP OF METADATA
    {
      "cordova-plugin-exoplayer": "2.6.0"
    };
    // BOTTOM OF METADATA
    });
    