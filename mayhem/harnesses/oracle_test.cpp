/*
 * oracle_test.cpp — behavioral oracle for mayhem/test.sh
 *
 * Exercises log4cxx's core logging pipeline and PatternLayout formatting.
 * mayhem/test.sh greps for known output strings; a no-op/exit(0) PATCH produces no output
 * and fails every grep check (anti-reward-hacking, SPEC §6.3).
 *
 * Expected stdout lines (test.sh uses regex grep, not fixed-string):
 *   ...INFO...ORACLE_TEST_MESSAGE  (BasicConfigurator default layout, e.g. "0 [tid] INFO root - msg")
 *   ...WARN...ORACLE_WARN_ENTRY
 *   ...ERROR...ORACLE_ERROR_ENTRY
 *   PATTERN_OK:INFO  oracle - ORACLE_PATTERN_MESSAGE  (PatternLayout "%-5p %c - %m%n")
 */

#include <iostream>
#include <cstdlib>

#include <log4cxx/logger.h>
#include <log4cxx/logmanager.h>
#include <log4cxx/basicconfigurator.h>
#include <log4cxx/patternlayout.h>
#include <log4cxx/helpers/pool.h>
#include <log4cxx/spi/loggingevent.h>
#include <log4cxx/spi/location/locationinfo.h>
#include <log4cxx/level.h>
#include <log4cxx/logstring.h>

int main()
{
    // ── Part 1: BasicConfigurator (SimpleLayout → ConsoleAppender → stdout)
    // SimpleLayout emits "LEVEL - message\n".  test.sh greps for the literal strings.
    log4cxx::BasicConfigurator::configure();
    auto root = log4cxx::LogManager::getRootLogger();

    LOG4CXX_INFO(root,  "ORACLE_TEST_MESSAGE");
    LOG4CXX_WARN(root,  "ORACLE_WARN_ENTRY");
    LOG4CXX_ERROR(root, "ORACLE_ERROR_ENTRY");

    // ── Part 2: PatternLayout direct format (exercises PatternParser + PatternLayout pipeline)
    // Pattern "%-5p %c - %m%n" → "INFO  oracle - ORACLE_PATTERN_MESSAGE\n"
    auto layout = std::make_shared<log4cxx::PatternLayout>(LOG4CXX_STR("%-5p %c - %m%n"));
    log4cxx::helpers::Pool pool;

    // Build a LoggingEvent using the (logger, level, message, location) constructor.
    auto logger = log4cxx::LogManager::getLogger(LOG4CXX_STR("oracle"));
    log4cxx::spi::LoggingEventPtr event = std::make_shared<log4cxx::spi::LoggingEvent>(
        LOG4CXX_STR("oracle"),
        log4cxx::Level::getInfo(),
        LOG4CXX_STR("ORACLE_PATTERN_MESSAGE"),
        LOG4CXX_LOCATION);

    log4cxx::LogString formatted;
    layout->format(formatted, event, pool);

    // Strip trailing newline; emit with a sentinel prefix so test.sh can grep "PATTERN_OK:"
    while (!formatted.empty() && (formatted.back() == '\n' || formatted.back() == '\r'))
        formatted.pop_back();

    std::cout << "PATTERN_OK:" << formatted << std::endl;

    log4cxx::LogManager::shutdown();
    return EXIT_SUCCESS;
}
