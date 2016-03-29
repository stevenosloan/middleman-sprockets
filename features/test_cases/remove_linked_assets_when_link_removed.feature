Feature: Linked assets removed from sitemap when link is removed

  Background:
    Given a fixture app "base-app"
    And a file named "config.rb" with:
      """
      activate :sprockets
      sprockets.append_path File.join(root, 'vendor')
      """
    And a file named "source/javascripts/manifest.js" with:
      """
      //= link linked
      """
    And a file named "vendor/linked.js" with:
      """
      console.log('linked');
      """

  Scenario: If link is removed from manifest the linked file is remove from sitemap
    Given the Server is running

    When I go to "/assets/linked.js"
    Then I should see "console.log('linked');"

    Given the file "source/javascripts/manifest.js" has the contents
      """
      console.log('no-link');
      """

    When I go to "/javascripts/manifest.js"
    Then I should see "console.log('no-link');"

    When I go to "/assets/linked.js"
    Then the status code should be "404"


  Scenario: If a file containing a link is removed the linked file is remove from sitemap
    Given the Server is running

    When I go to "/assets/linked.js"
    Then I should see "console.log('linked');"

    Given the file "source/javascripts/manifest.js" is removed

    When I go to "/assets/linked.js"
    Then the status code should be "404"
