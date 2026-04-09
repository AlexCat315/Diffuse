/// Internationalization (i18n) - Guava Editor Qt
///
/// This directory contains all translation files for the Guava Editor.
/// 
/// File structure:
/// - en_US.h     - English (United States) translations
/// - zh_CN.h     - Chinese Simplified translations
/// - [ja_JP.h]   - Japanese translations (future)
/// - [fr_FR.h]   - French translations (future)
/// 
/// To add a new language:
/// 1. Create a new file: xx_YY.h
/// 2. Define: inline static const QMap<QString, QString> TRANSLATIONS_XX_YY = { ... }
/// 3. Update Translator.cpp: Add language detection in translate() function
///
/// Translator.cpp example:
///   if (currentLanguage_ == "ja_JP") {
///       translations = &TRANSLATIONS_JA_JP;
///   }
///
/// Language codes follow BCP 47 standard:
/// - en_US: English (United States)  
/// - zh_CN: Chinese (Simplified)
/// - ja_JP: Japanese
/// - fr_FR: French
/// - etc.

#pragma once

// Include all available translations
#include "en_US.h"
#include "zh_CN.h"
