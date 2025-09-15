{.used.}

import chronicles, results, unittest
import ../../libp2p/protocols/mix/[curve25519, tag_manager]

suite "tag_manager_tests":
  var tm: TagManager

  setup:
    tm = TagManager.new()

  teardown:
    tm.clearTags()

  test "add_and_check_tag":
    let
      tag = generateRandomFieldElement().expect("should generate FE")
      nonexistentTag = generateRandomFieldElement().expect("should generate FE")

    tm.addTag(tag)

    check:
      tm.isTagSeen(tag)
      not tm.isTagSeen(nonexistentTag)

  test "remove_tag":
    let tag = generateRandomFieldElement().expect("should generate FE")

    tm.addTag(tag)
    check tm.isTagSeen(tag)

    tm.removeTag(tag)
    check not tm.isTagSeen(tag)

  test "check_tag_presence":
    let tag = generateRandomFieldElement().expect("should generate FE")
    check not tm.isTagSeen(tag)

    tm.addTag(tag)
    check tm.isTagSeen(tag)

    tm.removeTag(tag)
    check not tm.isTagSeen(tag)

  test "handle_multiple_tags":
    let tag1 = generateRandomFieldElement().expect("should generate FE")
    let tag2 = generateRandomFieldElement().expect("should generate FE")

    tm.addTag(tag1)
    tm.addTag(tag2)

    check:
      tm.isTagSeen(tag1)
      tm.isTagSeen(tag2)

    tm.removeTag(tag1)
    tm.removeTag(tag2)

    check:
      not tm.isTagSeen(tag1)
      not tm.isTagSeen(tag2)
