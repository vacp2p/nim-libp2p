{.used.}

import chronicles, results, unittest
import ../../libp2p/protocols/mix/[curve25519, tag_manager]

suite "tag_manager_tests":
  var tm: TagManager

  setup:
    tm = TagManager.new()

  teardown:
    clearTags(tm)

  test "add_and_check_tag":
    let tagRes = generateRandomFieldElement()
    if tagRes.isErr:
      error "Generate random field element error", err = tagRes.error
      fail()
    let tag = tagRes.get()

    addTag(tm, tag)
    if not isTagSeen(tm, tag):
      error "Tag should be seen after adding", tag = tag
      fail()

    let nonexistentTagRes = generateRandomFieldElement()
    if nonexistentTagRes.isErr:
      error "Generate random field element error", err = nonexistentTagRes.error
      fail()
    let nonexistentTag = nonexistentTagRes.get()

    if isTagSeen(tm, nonexistentTag):
      error "Nonexistent tag should not be seen", tag = nonexistentTag
      fail()

  test "remove_tag":
    let tagRes = generateRandomFieldElement()
    if tagRes.isErr:
      error "Generate random field element error", err = tagRes.error
      fail()
    let tag = tagRes.get()

    addTag(tm, tag)
    if not isTagSeen(tm, tag):
      error "Tag should be seen after adding", tag = tag
      fail()

    removeTag(tm, tag)
    if isTagSeen(tm, tag):
      error "Tag should not be seen after removal", tag = tag
      fail()

  test "check_tag_presence":
    let tagRes = generateRandomFieldElement()
    if tagRes.isErr:
      error "Generate random field element error", err = tagRes.error
      fail()
    let tag = tagRes.get()

    if isTagSeen(tm, tag):
      error "Tag should not be seen initially", tag = tag
      fail()

    addTag(tm, tag)
    if not isTagSeen(tm, tag):
      error "Tag should be seen after adding", tag = tag
      fail()

    removeTag(tm, tag)
    if isTagSeen(tm, tag):
      error "Tag should not be seen after removal", tag = tag
      fail()

  test "handle_multiple_tags":
    let tag1Res = generateRandomFieldElement()
    if tag1Res.isErr:
      error "Generate random field element error", err = tag1Res.error
      fail()
    let tag1 = tag1Res.get()

    let tag2Res = generateRandomFieldElement()
    if tag2Res.isErr:
      error "Generate random field element error", err = tag2Res.error
      fail()
    let tag2 = tag2Res.get()

    addTag(tm, tag1)
    addTag(tm, tag2)

    if not isTagSeen(tm, tag1) or not isTagSeen(tm, tag2):
      error "Both tags should be seen after adding", tag1 = tag1, tag2 = tag2
      fail()

    removeTag(tm, tag1)
    removeTag(tm, tag2)

    if isTagSeen(tm, tag1) or isTagSeen(tm, tag2):
      error "Both tags should not be seen after removal", tag1 = tag1, tag2 = tag2
      fail()
