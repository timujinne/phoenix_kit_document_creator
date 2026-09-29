defmodule PhoenixKitDocumentCreator.Integration.GoogleDocsClientHttpTest do
  @moduledoc """
  HTTP-bound coverage for `PhoenixKitDocumentCreator.GoogleDocsClient`.

  Each test stubs the `authenticated_request/4` contract via the
  `:integrations_backend` config, then drives a single public client
  function — confirming both the success path and the error-shape
  fallbacks (`{:error, :*_failed}` atoms surfaced when Drive returns
  non-2xx).
  """

  use PhoenixKitDocumentCreator.DataCase, async: false

  alias PhoenixKitDocumentCreator.GoogleDocsClient
  alias PhoenixKitDocumentCreator.Test.StubIntegrations

  setup do
    previous = Application.get_env(:phoenix_kit_document_creator, :integrations_backend)

    Application.put_env(
      :phoenix_kit_document_creator,
      :integrations_backend,
      StubIntegrations
    )

    StubIntegrations.reset!()
    StubIntegrations.connected!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_document_creator, :integrations_backend, previous),
        else: Application.delete_env(:phoenix_kit_document_creator, :integrations_backend)
    end)

    :ok
  end

  describe "find_folder_by_name/2" do
    test "returns {:ok, id} when Drive matches a folder by name" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => [%{"id" => "folder-Z", "name" => "Templates"}]}}}
      )

      assert {:ok, "folder-Z"} = GoogleDocsClient.find_folder_by_name("Templates")
    end

    test "returns {:error, :not_found} when no folder matches" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:error, :not_found} = GoogleDocsClient.find_folder_by_name("Missing")
    end

    test "returns {:error, :folder_search_failed} on 5xx" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      assert {:error, :folder_search_failed} = GoogleDocsClient.find_folder_by_name("X")
    end

    test "escapes single quotes in name (Drive query injection guard)" do
      # Stub returns OK regardless — the assertion is the lack of crash
      # on a quoted name. The escape happens before query construction.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      assert {:error, :not_found} =
               GoogleDocsClient.find_folder_by_name("Folder'with'quotes")
    end
  end

  describe "create_folder/2" do
    test "returns {:ok, id} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "new-folder-1"}}}
      )

      assert {:ok, "new-folder-1"} = GoogleDocsClient.create_folder("New Folder")
    end

    test "returns {:error, :create_folder_failed} on non-2xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :create_folder_failed} = GoogleDocsClient.create_folder("X")
    end

    test "passes through transport errors" do
      StubIntegrations.stub_request(:post, "/drive/v3/files", {:error, :timeout})
      assert {:error, :timeout} = GoogleDocsClient.create_folder("X")
    end
  end

  describe "find_or_create_folder/2" do
    test "returns existing folder id without creating" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => [%{"id" => "existing", "name" => "X"}]}}}
      )

      assert {:ok, "existing"} = GoogleDocsClient.find_or_create_folder("X")
    end

    test "creates folder when not found" do
      # Implement the search→empty, then create fallback. The stub
      # dispatches by method, so the GET search returns empty and the
      # POST create returns the new id.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "created"}}}
      )

      assert {:ok, "created"} = GoogleDocsClient.find_or_create_folder("X")
    end
  end

  describe "ensure_folder_path/2" do
    test "walks segment-by-segment, creating each folder on the path" do
      # Search returns nothing for each segment → POST creates each.
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"files" => []}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "leaf-folder"}}}
      )

      assert {:ok, "leaf-folder"} = GoogleDocsClient.ensure_folder_path("clients/active")
    end

    test "halts on the first error" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "drive down"}}}
      )

      assert {:error, :folder_search_failed} =
               GoogleDocsClient.ensure_folder_path("a/b/c")
    end
  end

  describe "create_document/2" do
    test "returns {:ok, %{doc_id, name, url}} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "doc-new", "name" => "My Doc"}}}
      )

      assert {:ok, %{doc_id: "doc-new", name: "My Doc", url: url}} =
               GoogleDocsClient.create_document("My Doc")

      assert is_binary(url)
      assert url =~ "doc-new"
    end

    test "returns {:error, :create_document_failed} on 5xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :create_document_failed} = GoogleDocsClient.create_document("X")
    end
  end

  describe "get_document/1" do
    test "returns {:ok, response} on 200 with the body intact" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok, %{status: 200, body: %{"documentId" => "doc-1"}}}
      )

      assert {:ok, %{body: %{"documentId" => "doc-1"}}} = GoogleDocsClient.get_document("doc-1")
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.get_document("../etc")
    end

    # Regression: without the status check a 404 error body flowed into the
    # append pipeline as a "document", document_end_index/1 read it as 1,
    # and the appended section landed at the top of the target document.
    test "returns {:error, :get_document_failed} on 404" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-404",
        {:ok, %{status: 404, body: %{"error" => %{"code" => 404, "message" => "Not found"}}}}
      )

      assert {:error, :get_document_failed} = GoogleDocsClient.get_document("doc-404")
    end

    test "returns {:error, :get_document_failed} on 5xx" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-500",
        {:ok, %{status: 500, body: %{"error" => %{"message" => "backend"}}}}
      )

      assert {:error, :get_document_failed} = GoogleDocsClient.get_document("doc-500")
    end
  end

  describe "batch_update/2" do
    test "returns {:ok, response} on 200" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      assert {:ok, %{body: %{"replies" => []}}} =
               GoogleDocsClient.batch_update("doc-1", [%{insertText: %{}}])
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.batch_update("../bad", [])
    end

    # Regression for the silent-batchUpdate bug: a 400 used to come back as
    # {:ok, resp} and every caller reported success on an unmodified doc.
    test "returns {:error, :batch_update_failed} on 400" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok,
         %{status: 400, body: %{"error" => %{"code" => 400, "message" => "Invalid request"}}}}
      )

      assert {:error, :batch_update_failed} =
               GoogleDocsClient.batch_update("doc-1", [%{insertText: %{}}])
    end
  end

  describe "substitute_all_sections/3 — blank variable handling" do
    # Google's batchUpdate is atomic and rejects insertText with empty text,
    # so a single blank variable used to void every substitution in the
    # batch. A blank value must emit ONLY the deleteContentRange.
    test "a blank value clears its placeholder without a paired insertText" do
      doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{
                    "startIndex" => 1,
                    "textRun" => %{"content" => "Hi {{a}} and {{b}}!\n"}
                  }
                ]
              }
            }
          ]
        }
      }

      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-sub",
        {:ok, %{status: 200, body: doc}}
      )

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [%{position: 0, variable_values: %{"a" => "X", "b" => ""}, image_params: %{}}]
      ranges = %{0 => {1, 30}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-sub", sections, ranges)

      batch_bodies =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            do: opts[:json].requests

      # One text-phase batch (no image fills → no image batch), in
      # descending index order: {{b}} (blank → delete only), then {{a}}
      # (delete + insert).
      assert [
               [
                 %{deleteContentRange: %{range: %{startIndex: 14, endIndex: 19}}},
                 %{deleteContentRange: %{range: %{startIndex: 4, endIndex: 9}}},
                 %{insertText: %{location: %{index: 4}, text: "X"}}
               ]
             ] = batch_bodies
    end
  end

  describe "substitute_all_sections/3 — section ranges after text substitution" do
    # Text substitution changes the document's length, moving every index that
    # follows an edit. The image phase re-fetches the document (so marker
    # indices are current) but used to match those fresh indices against the
    # PRE-substitution section ranges: in a multi-section compose, a later
    # section's `{{ images: name }}` marker drifts out of its own stale range
    # and is silently skipped — no images, no error.
    test "an image marker that shifted with the text is still filled" do
      # Section 0 holds a placeholder that SHRINKS by 10 units when filled
      # ("{{ customer }}" = 14 → "Acme" = 4); section 1 holds the image marker.
      before_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: {{ customer }}\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 25, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        }
      }

      # What the second GET sees: section 0's text is now 10 units shorter, so
      # the marker sits at 15 instead of 25.
      after_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: Acme\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 15, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        }
      }

      calls = start_supervised!({Agent, fn -> 0 end})

      StubIntegrations.stub_request(:get, "/v1/documents/doc-shift", fn ->
        n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
        {:ok, %{status: 200, body: if(n == 0, do: before_doc, else: after_doc)}}
      end)

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{position: 0, variable_values: %{"customer" => "Acme"}, image_params: %{}},
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" => %{
              "kind" => "image_list",
              "columns" => 1,
              "width_px" => 300,
              "media" => [%{"uri" => "https://example.test/a.png"}]
            }
          }
        }
      ]

      ranges = %{0 => {1, 25}, 1 => {25, 46}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-shift", sections, ranges)

      image_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            Map.has_key?(request, :insertInlineImage),
            do: request

      assert [%{insertInlineImage: %{uri: "https://example.test/a.png"}}] = image_requests
    end
  end

  describe "substitute_all_sections/3 — control characters Google strips from insertText" do
    # `insertText` doesn't store a value verbatim: per the Docs API reference,
    # it strips control characters (U+0000-U+0008, U+000C-U+001F — this
    # includes CR, U+000D) and Private Use Area code points (U+E000-U+F8FF).
    # A `:multiline` value from a <textarea> routinely carries CRLF line
    # endings, so counting the raw value overstates the delta Google actually
    # applies and drags every later section boundary right.
    #
    # "{{ notes }}" (11 units) is replaced by "rida1\r\nrida2\r\nrida3" — 19
    # units raw, 17 once the two CRs are stripped. Section 1's image marker
    # sits exactly at the correctly-shifted boundary (30 + 6 = 36); with the
    # old unsanitized delta (+8) it would land outside the (wrongly) shifted
    # range and be silently dropped — the same failure mode this PR exists
    # to fix, reached through a different door.
    test "a multiline value's CR is excluded from the shift delta, keeping the next section's image marker in range" do
      before_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "{{ notes }}\n"}}
                ]
              }
            }
          ]
        }
      }

      after_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "rida1\nrida2\nrida3\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 36, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        }
      }

      calls = start_supervised!({Agent, fn -> 0 end})

      StubIntegrations.stub_request(:get, "/v1/documents/doc-crlf", fn ->
        n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
        {:ok, %{status: 200, body: if(n == 0, do: before_doc, else: after_doc)}}
      end)

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{
          position: 0,
          variable_values: %{"notes" => "rida1\r\nrida2\r\nrida3"},
          image_params: %{}
        },
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" => %{
              "kind" => "image_list",
              "columns" => 1,
              "width_px" => 300,
              "media" => [%{"uri" => "https://example.test/a.png"}]
            }
          }
        }
      ]

      ranges = %{0 => {1, 30}, 1 => {30, 60}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-crlf", sections, ranges)

      all_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            do: request

      # The insertText we actually send already has the CR stripped — the
      # same string the delta was computed from, not the raw form value.
      assert %{insertText: %{text: "rida1\nrida2\nrida3"}} =
               Enum.find(all_requests, &match?(%{insertText: _}, &1))

      image_requests = Enum.filter(all_requests, &match?(%{insertInlineImage: _}, &1))

      assert [%{insertInlineImage: %{uri: "https://example.test/a.png"}}] = image_requests
    end
  end

  describe "substitute_all_sections/3 — header and footer text substitution" do
    # A composed document only ever inherits the FIRST section's headers/footers
    # (copy_document/2 copies them; append_template/3 appends body content only),
    # so a header/footer placeholder must resolve against the lowest-position
    # section regardless of which section's body range the reader's eye is near.
    test "substitutes a placeholder in a header, scoped to its segmentId" do
      doc = %{
        "body" => %{"content" => []},
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 1, "textRun" => %{"content" => "Order {{ order_no }}\n"}}
                  ]
                }
              }
            ]
          }
        }
      }

      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-header",
        {:ok, %{status: 200, body: doc}}
      )

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [%{position: 0, variable_values: %{"order_no" => "42"}, image_params: %{}}]
      ranges = %{0 => {1, 1}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-header", sections, ranges)

      batch_bodies =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            do: opts[:json].requests

      assert [
               [
                 %{
                   deleteContentRange: %{
                     range: %{startIndex: 7, endIndex: 21, segmentId: "kix.h1"}
                   }
                 },
                 %{insertText: %{location: %{index: 7, segmentId: "kix.h1"}, text: "42"}}
               ]
             ] = batch_bodies
    end

    test "footer placeholder resolves against the first section, not a later one that also defines the key" do
      doc = %{
        "body" => %{"content" => []},
        "footers" => %{
          "kix.f1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 1, "textRun" => %{"content" => "{{ company }}\n"}}
                  ]
                }
              }
            ]
          }
        }
      }

      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-footer",
        {:ok, %{status: 200, body: doc}}
      )

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{position: 0, variable_values: %{"company" => "First Co"}, image_params: %{}},
        %{position: 1, variable_values: %{"company" => "Second Co"}, image_params: %{}}
      ]

      ranges = %{0 => {1, 1}, 1 => {1, 1}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-footer", sections, ranges)

      insert_texts =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            %{insertText: %{text: text}} <- [request],
            do: text

      assert insert_texts == ["First Co"]
    end

    test "a header replacement's delta doesn't leak into body section boundaries" do
      # Section 0 holds both a body placeholder ("{{ customer }}", shrinks by
      # 10) and, via the header, a much-longer placeholder that shrinks by 30.
      # Section 1's image marker is positioned exactly where it should land
      # after ONLY the body delta is applied (25 - 10 = 15). If the header's
      # delta leaked into shift_ranges/2, the marker would be searched for at
      # the wrong index and silently dropped — the same failure class as the
      # body-only "section ranges after text substitution" test above, now
      # guarding against a header/footer-shaped version of it.
      before_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: {{ customer }}\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 25, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        },
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{
                      "startIndex" => 1,
                      "textRun" => %{"content" => "{{ a_much_longer_placeholder }}\n"}
                    }
                  ]
                }
              }
            ]
          }
        }
      }

      after_doc = %{
        "body" => %{
          "content" => [
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "textRun" => %{"content" => "Tellija: Acme\n"}}
                ]
              }
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 15, "textRun" => %{"content" => "{{ images: photos }}\n"}}
                ]
              }
            }
          ]
        },
        "headers" => %{
          "kix.h1" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 1, "textRun" => %{"content" => "x\n"}}
                  ]
                }
              }
            ]
          }
        }
      }

      calls = start_supervised!({Agent, fn -> 0 end})

      StubIntegrations.stub_request(:get, "/v1/documents/doc-header-shift", fn ->
        n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
        {:ok, %{status: 200, body: if(n == 0, do: before_doc, else: after_doc)}}
      end)

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{
          position: 0,
          variable_values: %{"customer" => "Acme", "a_much_longer_placeholder" => "x"},
          image_params: %{}
        },
        %{
          position: 1,
          variable_values: %{},
          image_params: %{
            "photos" => %{
              "kind" => "image_list",
              "columns" => 1,
              "width_px" => 300,
              "media" => [%{"uri" => "https://example.test/a.png"}]
            }
          }
        }
      ]

      ranges = %{0 => {1, 25}, 1 => {25, 46}}

      assert :ok =
               GoogleDocsClient.substitute_all_sections("doc-header-shift", sections, ranges)

      image_requests =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            Map.has_key?(request, :insertInlineImage),
            do: request

      assert [%{insertInlineImage: %{uri: "https://example.test/a.png"}}] = image_requests
    end

    test "a section that got its own header (Block C) substitutes it with that section's own values, not the first section's" do
      # Two REAL sections (an explicit sectionBreak, not the degenerate
      # `"body" => %{"content" => []}` fixtures above) — section 1's own
      # sectionBreak carries its own `defaultHeaderId`, simulating
      # `append_template/3` having given it a replayed copy of its
      # template's header (see google_docs_client_header_footer_test.exs).
      # Both headers share the same placeholder key; each must resolve
      # against the section that OWNS its segment, not against section 0
      # just because it has the lowest position.
      doc = %{
        "documentStyle" => %{"defaultHeaderId" => "kix.home"},
        "headers" => %{
          "kix.home" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 1, "textRun" => %{"content" => "{{ title }}\n"}}
                  ]
                }
              }
            ]
          },
          "kix.own" => %{
            "content" => [
              %{
                "paragraph" => %{
                  "elements" => [
                    %{"startIndex" => 1, "textRun" => %{"content" => "{{ title }}\n"}}
                  ]
                }
              }
            ]
          }
        },
        "body" => %{
          "content" => [
            %{"sectionBreak" => %{"sectionStyle" => %{}}},
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 1, "endIndex" => 5, "textRun" => %{"content" => "Sec0\n"}}
                ]
              }
            },
            %{
              "startIndex" => 5,
              "sectionBreak" => %{"sectionStyle" => %{"defaultHeaderId" => "kix.own"}}
            },
            %{
              "paragraph" => %{
                "elements" => [
                  %{"startIndex" => 6, "endIndex" => 10, "textRun" => %{"content" => "Sec1\n"}}
                ]
              }
            }
          ]
        }
      }

      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-mixed-headers",
        {:ok, %{status: 200, body: doc}}
      )

      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      sections = [
        %{position: 0, variable_values: %{"title" => "Home title"}, image_params: %{}},
        %{position: 1, variable_values: %{"title" => "Section 1 title"}, image_params: %{}}
      ]

      ranges = %{0 => {1, 5}, 1 => {6, 10}}

      assert :ok = GoogleDocsClient.substitute_all_sections("doc-mixed-headers", sections, ranges)

      text_by_segment =
        for {:post, url, opts} <- StubIntegrations.recorded_requests(),
            String.contains?(url, ":batchUpdate"),
            request <- opts[:json].requests,
            %{insertText: %{location: %{segmentId: segment_id}, text: text}} <- [request],
            into: %{},
            do: {segment_id, text}

      assert text_by_segment == %{"kix.home" => "Home title", "kix.own" => "Section 1 title"}
    end
  end

  describe "shift_ranges/2" do
    test "moves boundaries by the net length change of earlier replacements" do
      # "{{ a }}" (7 units) → "LONGER" (6): −1, starting at index 3.
      replacements = [{"a", 3, 10, "LONGER"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}, 1 => {20, 40}}, replacements) ==
               %{0 => {1, 19}, 1 => {19, 39}}
    end

    test "leaves a boundary that precedes every replacement untouched" do
      replacements = [{"a", 30, 40, "x"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}, 1 => {20, 60}}, replacements) ==
               %{0 => {1, 20}, 1 => {20, 51}}
    end

    test "counts a replacement value in UTF-16 code units, not bytes" do
      # "õ" is 2 bytes in UTF-8 but 1 unit in Google's indexing; a 5-unit
      # placeholder replaced by "Kõiv" (4 units) shifts later text by −1.
      replacements = [{"a", 5, 10, "Kõiv"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 30}}, replacements) == %{0 => {1, 29}}
    end

    test "counts a supplementary-plane character as two UTF-16 units" do
      # The test above only rules out byte counting — "Kõiv" is 4 characters
      # AND 4 UTF-16 units, so a codepoint-counting implementation would pass
      # it too. An emoji separates the two: "a🎉b" is 3 codepoints but 4 UTF-16
      # units, because U+1F389 is stored as a surrogate pair, and Google's
      # indices count those as two. A 5-unit placeholder replaced by it
      # therefore shifts later text by −1, not −2.
      replacements = [{"a", 5, 10, "a🎉b"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 30}}, replacements) == %{0 => {1, 29}}
    end

    test "returns the ranges unchanged when nothing was replaced" do
      assert GoogleDocsClient.shift_ranges(%{0 => {1, 20}}, []) == %{0 => {1, 20}}
    end

    test "a replacement starting exactly on a boundary belongs to the following section and doesn't move that boundary's start" do
      # "{{ k }}" → "x" (1 unit) replaces the 10 units at [50, 60), which is
      # both section 0's end and section 1's start. It must not move either
      # boundary's *start* (a replacement starting exactly at index N doesn't
      # count toward `shift_at(deltas, N)`), but it does move section 1's end.
      replacements = [{"k", 50, 60, "x"}]

      assert GoogleDocsClient.shift_ranges(%{0 => {1, 50}, 1 => {50, 100}}, replacements) ==
               %{0 => {1, 50}, 1 => {50, 91}}
    end
  end

  describe "replace_all_text/2" do
    test "delegates to batch_update for non-empty variables" do
      StubIntegrations.stub_request(
        :post,
        ":batchUpdate",
        {:ok, %{status: 200, body: %{"replies" => []}}}
      )

      assert {:ok, _} = GoogleDocsClient.replace_all_text("doc-1", %{"name" => "Acme"})
    end
  end

  describe "get_document_text/1" do
    test "extracts plain text from a Google Doc body" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok,
         %{
           status: 200,
           body: %{
             "body" => %{
               "content" => [
                 %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "Hello "}}]}},
                 %{"paragraph" => %{"elements" => [%{"textRun" => %{"content" => "World"}}]}}
               ]
             }
           }
         }}
      )

      assert {:ok, "Hello World"} = GoogleDocsClient.get_document_text("doc-1")
    end

    test "propagates :error from get_document" do
      StubIntegrations.stub_request(
        :get,
        "/v1/documents/doc-1",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      # `get_document/1` checks the HTTP status (same contract as
      # `batch_update/2`) — a non-2xx no longer surfaces its error body
      # as a document, it fails loudly.
      assert {:error, :get_document_failed} = GoogleDocsClient.get_document_text("doc-1")
    end
  end

  describe "copy_file/3" do
    test "returns {:ok, new_id} on 200" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/src-file/copy",
        {:ok, %{status: 200, body: %{"id" => "copy-1"}}}
      )

      assert {:ok, "copy-1"} = GoogleDocsClient.copy_file("src-file", "Copy")
    end

    test "rejects invalid source id" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.copy_file("bad/id", "Copy")
    end

    test "returns {:error, :copy_failed} on non-2xx" do
      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/src-file/copy",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :copy_failed} = GoogleDocsClient.copy_file("src-file", "Copy")
    end
  end

  describe "export_pdf/1" do
    test "returns {:ok, pdf_binary} on 200" do
      pdf_body = String.duplicate("PDF", 50)

      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 200, body: pdf_body, headers: %{}}}
      )

      assert {:ok, ^pdf_body} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "rejects invalid file id without HTTP" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.export_pdf("../bad")
    end

    test "returns {:error, :pdf_export_failed} on non-200" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :pdf_export_failed} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :drive_file_not_found} on 404 (Drive file deleted)" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 404, body: %{"error" => %{"errors" => [%{"reason" => "notFound"}]}}}}
      )

      assert {:error, :drive_file_not_found} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :drive_forbidden} on 403 (service account can't read file)" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 403, body: %{"error" => %{"errors" => [%{"reason" => "forbidden"}]}}}}
      )

      assert {:error, :drive_forbidden} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :drive_rate_limited} on 403 with a rate/quota limit reason" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok,
         %{
           status: 403,
           body: %{"error" => %{"errors" => [%{"reason" => "userRateLimitExceeded"}]}}
         }}
      )

      assert {:error, :drive_rate_limited} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :pdf_export_failed} on 403 with an unrecognized reason" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 403, body: %{"error" => %{"errors" => [%{"reason" => "somethingElse"}]}}}}
      )

      assert {:error, :pdf_export_failed} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :pdf_export_failed} on 403 with a body that has no errors list" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 403, body: %{"error" => "boom"}}}
      )

      assert {:error, :pdf_export_failed} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :drive_forbidden} on 403 teamDriveMembershipRequired" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok,
         %{
           status: 403,
           body: %{"error" => %{"errors" => [%{"reason" => "teamDriveMembershipRequired"}]}}
         }}
      )

      assert {:error, :drive_forbidden} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "returns {:error, :drive_export_too_large} on 403 exportSizeLimitExceeded when the export link can't be read either" do
      stub_export_too_large("doc-1")

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/doc-1$},
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :drive_export_too_large} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "past the export size cap, downloads the PDF from the file's exportLinks" do
      pdf_body = "%PDF-1.4\n" <> String.duplicate("PDF", 50)

      link =
        "https://docs.google.com/feeds/download/documents/export/Export?id=doc-1&exportFormat=pdf"

      stub_export_too_large("doc-1")
      stub_export_links("doc-1", link)

      StubIntegrations.stub_request(
        :get,
        "docs.google.com/feeds/download",
        {:ok, %{status: 200, body: pdf_body, headers: %{}}}
      )

      assert {:ok, ^pdf_body} = GoogleDocsClient.export_pdf("doc-1")

      assert Enum.any?(StubIntegrations.recorded_requests(), fn {method, url, opts} ->
               method == :get and url == link and opts[:receive_timeout] > 15_000
             end)
    end

    test "past the export size cap, rejects a 200 export link answer that is not a PDF" do
      stub_export_too_large("doc-1")

      stub_export_links(
        "doc-1",
        "https://docs.google.com/feeds/download/documents/export/Export?id=doc-1&exportFormat=pdf"
      )

      StubIntegrations.stub_request(
        :get,
        "docs.google.com/feeds/download",
        {:ok, %{status: 200, body: "<!DOCTYPE html><html>Sign in</html>", headers: %{}}}
      )

      assert {:error, :drive_export_too_large} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "past the export size cap, reports :drive_export_too_large when exportLinks has no usable PDF link" do
      stub_export_too_large("doc-1")
      stub_export_links("doc-1", nil)

      assert {:error, :drive_export_too_large} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "past the export size cap, never sends the token to an export link off docs.google.com" do
      stub_export_too_large("doc-1")
      stub_export_links("doc-1", "https://evil.example/Export?id=doc-1")

      assert {:error, :drive_export_too_large} = GoogleDocsClient.export_pdf("doc-1")

      refute Enum.any?(StubIntegrations.recorded_requests(), fn {_, url, _} ->
               String.contains?(url, "evil.example")
             end)
    end

    test "past the export size cap, reports :drive_export_too_large when the export link fails" do
      stub_export_too_large("doc-1")

      stub_export_links(
        "doc-1",
        "https://docs.google.com/feeds/download/documents/export/Export?id=doc-1&exportFormat=pdf"
      )

      StubIntegrations.stub_request(
        :get,
        "docs.google.com/feeds/download",
        {:ok, %{status: 500, body: "boom"}}
      )

      assert {:error, :drive_export_too_large} = GoogleDocsClient.export_pdf("doc-1")
    end

    test "classifies the single-error `error.reason` shape too" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-1/export",
        {:ok, %{status: 403, body: %{"error" => %{"reason" => "rateLimitExceeded"}}}}
      )

      assert {:error, :drive_rate_limited} = GoogleDocsClient.export_pdf("doc-1")
    end
  end

  defp stub_export_too_large(file_id) do
    StubIntegrations.stub_request(
      :get,
      "/drive/v3/files/#{file_id}/export",
      {:ok,
       %{
         status: 403,
         body: %{"error" => %{"errors" => [%{"reason" => "exportSizeLimitExceeded"}]}}
       }}
    )
  end

  defp stub_export_links(file_id, pdf_link) do
    StubIntegrations.stub_request(
      :get,
      ~r{/drive/v3/files/#{Regex.escape(file_id)}$},
      {:ok, %{status: 200, body: %{"exportLinks" => %{"application/pdf" => pdf_link}}}}
    )
  end

  describe "upload_image_for_embedding/3" do
    test "returns an lh3 URL that asks for the image at up to 4096px, not the 1600px default" do
      StubIntegrations.stub_request(
        :post,
        "/upload/drive/v3/files",
        {:ok, %{status: 200, body: %{"id" => "img-1"}}}
      )

      StubIntegrations.stub_request(
        :post,
        "/drive/v3/files/img-1/permissions",
        {:ok, %{status: 200, body: %{}}}
      )

      assert {:ok, "https://lh3.googleusercontent.com/d/img-1=s4096"} =
               GoogleDocsClient.upload_image_for_embedding("PNGDATA", "image/png")
    end
  end

  describe "move_file/2 (HTTP)" do
    test "succeeds with GET parents → PATCH addParents/removeParents" do
      file_id = "move-1"

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old-parent"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 200, body: %{"id" => file_id}}}
      )

      assert :ok = GoogleDocsClient.move_file(file_id, "new-parent")
    end

    test "returns :move_failed when PATCH 5xxs" do
      file_id = "move-2"

      StubIntegrations.stub_request(
        :get,
        ~r{/drive/v3/files/#{Regex.escape(file_id)}(\?|$)},
        {:ok, %{status: 200, body: %{"id" => file_id, "parents" => ["old"]}}}
      )

      StubIntegrations.stub_request(
        :patch,
        "/drive/v3/files/#{file_id}",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :move_failed} = GoogleDocsClient.move_file(file_id, "new")
    end

    test "returns :get_file_parents_failed when GET 5xxs" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/move-3",
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      )

      assert {:error, :get_file_parents_failed} = GoogleDocsClient.move_file("move-3", "dst")
    end
  end

  describe "file_status/1 + file_location/1" do
    test "file_status returns map with parents + trashed" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-9",
        {:ok, %{status: 200, body: %{"id" => "doc-9", "parents" => ["root"], "trashed" => false}}}
      )

      assert {:ok, %{parents: ["root"], trashed: false}} = GoogleDocsClient.file_status("doc-9")
    end

    test "file_status :ok :not_found on 404" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/ghost",
        {:ok, %{status: 404, body: %{}}}
      )

      assert {:ok, :not_found} = GoogleDocsClient.file_status("ghost")
    end

    test "file_location resolves the parent path back to root" do
      StubIntegrations.stub_request(
        :get,
        "/drive/v3/files/doc-9",
        {:ok, %{status: 200, body: %{"id" => "doc-9", "parents" => ["root"], "trashed" => false}}}
      )

      assert {:ok, %{folder_id: "root", path: ""}} = GoogleDocsClient.file_location("doc-9")
    end
  end

  describe "get_credentials/0 + connection_status/0" do
    test "get_credentials returns the stub's :ok payload when connected" do
      assert {:ok, %{access_token: "stub-token"}} = GoogleDocsClient.get_credentials()
    end

    test "connection_status returns the stubbed email when connected" do
      assert {:ok, %{email: "test@example.com"}} = GoogleDocsClient.connection_status()
    end

    test "connection_status returns :not_configured when disconnected" do
      StubIntegrations.disconnected!()
      assert {:error, :not_configured} = GoogleDocsClient.connection_status()
    end
  end

  describe "get_folder_url/1" do
    test "returns the canonical Drive URL for a folder" do
      assert "https://drive.google.com/drive/folders/abc123" =
               GoogleDocsClient.get_folder_url("abc123")
    end

    test "returns nil for empty / nil input" do
      assert GoogleDocsClient.get_folder_url("") == nil
      assert GoogleDocsClient.get_folder_url(nil) == nil
    end
  end

  describe "get_edit_url/1" do
    test "returns canonical Docs edit URL for valid id" do
      assert "https://docs.google.com/document/d/abc/edit" =
               GoogleDocsClient.get_edit_url("abc")
    end

    test "returns nil for nil / empty" do
      assert GoogleDocsClient.get_edit_url("") == nil
      assert GoogleDocsClient.get_edit_url(nil) == nil
    end
  end
end
